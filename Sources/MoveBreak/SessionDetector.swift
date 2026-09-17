import Foundation

/// What kind of sedentary session we think you're in.
enum SessionState: Equatable {
    case idle
    case meeting
    case video

    var isActive: Bool { self != .idle }

    var label: String {
        switch self {
        case .idle:    return "idle"
        case .meeting: return "meeting"
        case .video:   return "video"
        }
    }
}

/// Full detail of one classification pass, for `--diagnose`.
struct Classification {
    let state: SessionState
    let reason: String
    let activeProcesses: [AudioProcess]
    let inspections: [TabInspection]
}

/// Turns audio-stream state into session state, then into "should we prompt".
///
/// Three stages, cheapest and most certain first:
///   1. a meeting app holds a live *mic* stream        -> meeting
///   2. a native player holds a live *output* stream   -> video
///   3. a browser holds a live output stream           -> ask what's in its tabs
///
/// Only stage 3 costs an Apple Event, and only while something is actually playing.
final class SessionDetector {

    private let monitor = AudioActivityMonitor()
    private let tabInspector = BrowserTabInspector()

    // Debounce: a candidate state must repeat before we believe it. Notification sounds
    // open an output stream for a fraction of a second and would otherwise register.
    private var candidateState: SessionState = .idle
    private var candidateCount = 0
    private(set) var state: SessionState = .idle

    // Session lifecycle
    private var idleSince: Date?
    private(set) var sessionID = 0
    private var promptedForSession: Int?
    private var suppressedUntil: Date?

    /// Called when a new session begins and we should prompt. Set by AppDelegate.
    var onPromptDue: ((SessionState) -> Void)?

    // MARK: - Polling

    /// One classification pass. Returns detail for diagnostics; side effects go through
    /// `onPromptDue`.
    @discardableResult
    func poll() -> Classification {
        RunningAppLookup.shared.invalidate()

        let classification = classify()
        apply(classification.state)
        return classification
    }

    private func classify() -> Classification {
        let active = monitor.activeSnapshot()
        return Self.classify(
            processes: active,
            ignoredApps: Preferences.ignoredApps,
            meetingApps: Preferences.meetingApps,
            nativePlayers: Preferences.nativePlayers,
            browsers: Preferences.browsers,
            tabInspector: { [tabInspector] bundleID in
                tabInspector.inspect(bundleID: bundleID)
            }
        )
    }

    /// Pure classification logic extracted from CoreAudio and AppleScript dependencies.
    /// Evaluates snapshot processes against app sets and invokes `tabInspector` only when
    /// an active, non-ignored browser holds an output stream.
    static func classify(
        processes active: [AudioProcess],
        ignoredApps: Set<String> = Preferences.ignoredApps,
        meetingApps: Set<String> = Preferences.meetingApps,
        nativePlayers: Set<String> = Preferences.nativePlayers,
        browsers: Set<String> = Preferences.browsers,
        tabInspector: (String) -> TabInspection
    ) -> Classification {
        // Ignored apps are unconditionally excluded before mic, native-player,
        // and browser stages. Helper-to-owner resolution ensures helper processes
        // of ignored apps are also excluded.
        let relevant = active.filter { !BundleIdentity.belongs($0.bundleID, to: ignoredApps) }

        // Stage 1 — a live mic stream is unambiguous. No URL inspection needed, and it
        // covers Zoom, Meet, Teams, Slack and FaceTime through one code path.
        if let hit = relevant.first(where: {
            $0.isRunningInput && BundleIdentity.belongs($0.bundleID, to: meetingApps)
        }) {
            return Classification(
                state: .meeting,
                reason: "\(hit.bundleID ?? "?") holds a live input stream",
                activeProcesses: active,
                inspections: []
            )
        }

        // Stage 2 — native players need no disambiguation.
        if let hit = relevant.first(where: {
            $0.isRunningOutput && BundleIdentity.belongs($0.bundleID, to: nativePlayers)
        }) {
            return Classification(
                state: .video,
                reason: "\(hit.bundleID ?? "?") is playing",
                activeProcesses: active,
                inspections: []
            )
        }

        // Stage 3 — browser audio: could be a video, could be Relisten. Ask.
        // Resolve helper -> parent browser, and dedupe: Chrome can have several helper
        // processes holding streams at once, and they all mean the same browser.
        let playingBrowsers = Set(
            relevant
                .filter(\.isRunningOutput)
                .compactMap { process -> String? in
                    guard let bundleID = process.bundleID else { return nil }
                    return BundleIdentity.owner(of: bundleID, in: browsers)
                }
        ).sorted()

        var inspections: [TabInspection] = []
        for bundleID in playingBrowsers {
            let inspection = tabInspector(bundleID)
            inspections.append(inspection)
            switch inspection.verdict {
            case .meeting(let url):
                return Classification(
                    state: .meeting,
                    reason: "\(bundleID): \(inspection.reason) — \(URLDisplay.sanitize(url, verbose: false))",
                    activeProcesses: active,
                    inspections: inspections
                )
            case .video(let url):
                return Classification(
                    state: .video,
                    reason: "\(bundleID): \(inspection.reason) — \(URLDisplay.sanitize(url, verbose: false))",
                    activeProcesses: active,
                    inspections: inspections
                )
            case .music, .unknown:
                continue
            }
        }

        let reason: String
        if let first = inspections.first {
            // Something is playing in a browser but it isn't a video we recognise.
            // Bias is toward not prompting: a missed prompt costs nothing, an
            // interruption mid-song is exactly what we're avoiding.
            reason = "browser audio ignored — \(first.reason)"
        } else if relevant.isEmpty {
            reason = "no relevant audio streams"
        } else {
            reason = "streams present but none matched a rule"
        }

        return Classification(
            state: .idle, reason: reason, activeProcesses: active, inspections: inspections
        )
    }

    // MARK: - Debounce and session lifecycle

    private func apply(_ observed: SessionState) {
        if observed == candidateState {
            candidateCount += 1
        } else {
            candidateState = observed
            candidateCount = 1
        }

        guard candidateCount >= Preferences.debouncePolls, state != candidateState else {
            trackIdleGrace()
            return
        }

        let previous = state
        state = candidateState

        if state.isActive {
            idleSince = nil
            // A new session starts when we come up from idle. Meeting -> video (or the
            // reverse) inside one continuous stretch is not a new session; you never got
            // up, so you don't need a second prompt.
            if !previous.isActive {
                sessionID += 1
            }
            maybePrompt()
        } else {
            idleSince = Date()
        }
    }

    /// The session isn't over the instant audio stops — a brief gap between meetings, or
    /// a pause to answer a question, shouldn't re-arm the prompt.
    private func trackIdleGrace() {
        guard state == .idle, let idleSince else { return }
        if Date().timeIntervalSince(idleSince) > Preferences.sessionEndGrace {
            promptedForSession = nil
            self.idleSince = nil
        }
    }

    private func maybePrompt() {
        if let suppressedUntil, Date() < suppressedUntil { return }
        if promptedForSession == sessionID { return }
        promptedForSession = sessionID
        onPromptDue?(state)
    }

    // MARK: - Responses to the prompt

    func recordDecline() {
        suppressedUntil = Date().addingTimeInterval(Preferences.declineCooldown)
    }

    func recordTimeout() {
        suppressedUntil = Date().addingTimeInterval(Preferences.timeoutCooldown)
    }

    /// A finished routine suppresses only until the next session, not on a clock.
    func recordRoutineStarted() {
        promptedForSession = sessionID
    }

    var isSupported: Bool { AudioActivityMonitor.isSupported }
}
