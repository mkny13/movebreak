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

/// Deterministic debounce and session bookkeeping. Keeping time and policy inputs here
/// makes lifecycle behavior testable without CoreAudio, AppleScript, or wall-clock sleeps.
struct SessionLifecycle {
    struct Configuration {
        let debouncePolls: Int
        let sessionEndGrace: TimeInterval
        let declineCooldown: TimeInterval
        let timeoutCooldown: TimeInterval

        static var current: Configuration {
            Configuration(
                debouncePolls: Preferences.debouncePolls,
                sessionEndGrace: Preferences.sessionEndGrace,
                declineCooldown: Preferences.declineCooldown,
                timeoutCooldown: Preferences.timeoutCooldown
            )
        }
    }

    private let configuration: Configuration
    private let now: () -> Date

    private var candidateState: SessionState = .idle
    private var candidateCount = 0
    private(set) var state: SessionState = .idle
    private(set) var sessionID = 0
    private var sessionIsOpen = false
    private var idleSince: Date?
    private var promptedForSession: Int?
    private var suppressedUntil: Date?

    init(configuration: Configuration = .current, now: @escaping () -> Date = Date.init) {
        self.configuration = configuration
        self.now = now
    }

    /// Applies an observation and returns the active state when a prompt becomes due.
    mutating func observe(_ observed: SessionState) -> SessionState? {
        expireIdleGraceIfNeeded()

        if observed == candidateState {
            candidateCount += 1
        } else {
            candidateState = observed
            candidateCount = 1
        }

        if candidateCount >= configuration.debouncePolls, state != candidateState {
            let previous = state
            state = candidateState

            if state.isActive {
                idleSince = nil
                if !sessionIsOpen {
                    sessionIsOpen = true
                    sessionID += 1
                }
            } else if previous.isActive {
                idleSince = now()
            }
        }

        if state.isActive {
            return promptIfDue()
        }

        expireIdleGraceIfNeeded()
        return nil
    }

    private mutating func expireIdleGraceIfNeeded() {
        guard state == .idle,
              sessionIsOpen,
              let idleSince,
              now().timeIntervalSince(idleSince) > configuration.sessionEndGrace else {
            return
        }
        sessionIsOpen = false
        promptedForSession = nil
        self.idleSince = nil
    }

    private mutating func promptIfDue() -> SessionState? {
        if let suppressedUntil, now() < suppressedUntil { return nil }
        if promptedForSession == sessionID { return nil }
        promptedForSession = sessionID
        return state
    }

    mutating func recordDecline() {
        suppressedUntil = now().addingTimeInterval(configuration.declineCooldown)
    }

    mutating func recordTimeout() {
        suppressedUntil = now().addingTimeInterval(configuration.timeoutCooldown)
    }

    mutating func recordRoutineStarted() {
        promptedForSession = sessionID
    }
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

    private var lifecycle: SessionLifecycle

    /// Called when a new session begins and we should prompt. Set by AppDelegate.
    var onPromptDue: ((SessionState) -> Void)?

    init(
        lifecycleConfiguration: SessionLifecycle.Configuration = .current,
        now: @escaping () -> Date = Date.init
    ) {
        lifecycle = SessionLifecycle(configuration: lifecycleConfiguration, now: now)
    }

    var state: SessionState { lifecycle.state }
    var sessionID: Int { lifecycle.sessionID }

    // MARK: - Polling

    /// One classification pass. Returns detail for diagnostics; side effects go through
    /// `onPromptDue`.
    @discardableResult
    func poll() -> Classification {
        let classification = inspect()
        accept(classification)
        return classification
    }

    /// Performs the potentially slow I/O portion without mutating lifecycle state.
    func inspect() -> Classification {
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
        var firstVideo: (bundleID: String, inspection: TabInspection, url: String)?
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
                // Keep inspecting: a call in another playing browser outranks video,
                // regardless of the browsers' deterministic sort order.
                if firstVideo == nil {
                    firstVideo = (bundleID, inspection, url)
                }
            case .music, .unknown:
                continue
            }
        }

        if let firstVideo {
            return Classification(
                state: .video,
                reason: "\(firstVideo.bundleID): \(firstVideo.inspection.reason) — \(URLDisplay.sanitize(firstVideo.url, verbose: false))",
                activeProcesses: active,
                inspections: inspections
            )
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

    /// Applies a completed inspection. The app's serial scheduler calls this only when
    /// the poll still belongs to the current (unpaused) generation.
    func accept(_ classification: Classification) {
        if let promptState = lifecycle.observe(classification.state) {
            onPromptDue?(promptState)
        }
    }

    // MARK: - Responses to the prompt

    func recordDecline() {
        lifecycle.recordDecline()
    }

    func recordTimeout() {
        lifecycle.recordTimeout()
    }

    /// A finished routine suppresses only until the next session, not on a clock.
    func recordRoutineStarted() {
        lifecycle.recordRoutineStarted()
    }

    var isSupported: Bool { AudioActivityMonitor.isSupported }
}
