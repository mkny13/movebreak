import AppKit
import Foundation

/// What a browser's open tabs suggest is playing.
enum TabVerdict: Equatable {
    case meeting(String)    // matched a browser-call pattern; payload is the URL
    case video(String)      // matched a video pattern; payload is the URL
    case music(String)      // matched a music pattern; payload is the URL
    case unknown            // nothing matched, or the match was ambiguous

    var isVideo: Bool { if case .video = self { return true }; return false }
    var isMeeting: Bool { if case .meeting = self { return true }; return false }

    /// Whether this verdict should raise a prompt at all.
    var isActionable: Bool { isVideo || isMeeting }
}

/// Result of inspecting one browser, kept verbose so `--diagnose` can explain itself.
struct TabInspection {
    let bundleID: String
    let activeTabURL: String?
    let allTabURLs: [String]
    let verdict: TabVerdict
    let reason: String
    let scriptError: String?
}

/// Asks a browser what's open, so browser audio can be classified as video vs music.
///
/// Necessary because CoreAudio attributes all browser audio to the browser process itself
/// — Relisten and a YouTube video are indistinguishable at the bundle-ID level.
///
/// Chrome's scripting dictionary has no `audible` property, so there is no way to ask
/// which tab is the one making noise. Hence the precedence rule in `verdict(for:)`:
/// trust the *active* tab first, because that's the one you're looking at, and only fall
/// back to scanning every tab when the active one tells us nothing.
final class BrowserTabInspector {

    private var cache: [String: (inspection: TabInspection, timestamp: Date)] = [:]
    private let lock = NSLock()

    /// Inspect a browser, reusing a recent result if we have one.
    /// Only ever called when that browser actually holds a live output stream, so there
    /// is no steady-state Apple Event traffic.
    func inspect(bundleID: String) -> TabInspection {
        lock.lock()
        if let cached = cache[bundleID],
           Date().timeIntervalSince(cached.timestamp) < Preferences.tabCacheLifetime {
            lock.unlock()
            return cached.inspection
        }
        lock.unlock()

        let fresh = performInspection(bundleID: bundleID)

        lock.lock()
        cache[bundleID] = (fresh, Date())
        lock.unlock()
        return fresh
    }

    /// Bypasses the cache. Used by `--tabs` so repeated runs show current state.
    func inspectFresh(bundleID: String) -> TabInspection {
        performInspection(bundleID: bundleID)
    }

    // MARK: - Classification

    private func performInspection(bundleID: String) -> TabInspection {
        guard let dialect = Dialect(bundleID: bundleID) else {
            return TabInspection(
                bundleID: bundleID,
                activeTabURL: nil,
                allTabURLs: [],
                verdict: .unknown,
                reason: "no AppleScript tab support for this browser",
                scriptError: nil
            )
        }

        var scriptError: String?

        let activeURL = runScript(dialect.activeTabScript, error: &scriptError)?
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Only pay for the fallback scan if the active tab didn't settle it.
        let needsFallback = Self.classifyActiveTab(activeURL) == nil
        let allURLs = needsFallback
            ? (runScript(dialect.windowActiveTabsScript, error: &scriptError) ?? [])
            : []

        let (verdict, reason) = Self.classify(activeURL: activeURL, allURLs: allURLs)
        return TabInspection(
            bundleID: bundleID,
            activeTabURL: activeURL,
            allTabURLs: allURLs,
            verdict: verdict,
            reason: reason,
            scriptError: scriptError
        )
    }

    /// The precedence rule, kept free of AppleScript so it can be tested directly
    /// (`--self-test`) without a browser or an Automation grant.
    ///
    /// Step 1 trusts the active tab: if you're watching something, it's the tab you're
    /// looking at. Step 2 only fires on an unambiguous all-tabs result, because a wrong
    /// "video" here interrupts you mid-song — the expensive error.
    static func classify(activeURL: String?, allURLs: [String]) -> (TabVerdict, String) {
        if let settled = classifyActiveTab(activeURL) {
            return settled
        }

        // A live call outranks everything: it's the higher-value signal, and a meeting tab
        // that is active in its own window is strong evidence regardless of what else is
        // open. Music tabs do not suppress it.
        if let meetingHit = allURLs.first(where: { matches($0, Preferences.meetingPatterns) }) {
            return (.meeting(meetingHit), "a window-active tab is a call")
        }

        let musicHits = allURLs.filter { matches($0, Preferences.musicPatterns) }
        // A URL matching both lists is music: the music patterns are the more specific
        // ones (music.youtube.com/watch also contains youtube.com/watch).
        let videoHits = allURLs.filter {
            matches($0, Preferences.videoPatterns) && !matches($0, Preferences.musicPatterns)
        }

        if videoHits.count == 1 && musicHits.isEmpty {
            return (.video(videoHits[0]), "exactly one video tab, no music tabs")
        }
        if !musicHits.isEmpty && !videoHits.isEmpty {
            return (.unknown, "ambiguous: \(videoHits.count) video + \(musicHits.count) music tabs")
        }
        if !musicHits.isEmpty {
            return (.unknown, "music tab(s) open, no video")
        }
        if videoHits.count > 1 {
            return (.unknown, "ambiguous: \(videoHits.count) video tabs, none active")
        }
        return (.unknown, "no tab matched either list")
    }

    /// Returns nil when the active tab tells us nothing and we need the fallback scan.
    static func classifyActiveTab(_ activeURL: String?) -> (TabVerdict, String)? {
        guard let activeURL, !activeURL.isEmpty else { return nil }
        // Calls first — a Meet tab is a meeting whether or not the mic stream is open.
        if matches(activeURL, Preferences.meetingPatterns) {
            return (.meeting(activeURL), "active tab is a call")
        }
        // Music before video because its patterns are the more specific ones:
        // music.youtube.com/watch?v=… also contains the youtube.com/watch video pattern,
        // and it is not a video. Checking video first would misclassify it.
        if matches(activeURL, Preferences.musicPatterns) {
            return (.music(activeURL), "active tab matched musicPatterns")
        }
        if matches(activeURL, Preferences.videoPatterns) {
            return (.video(activeURL), "active tab matched videoPatterns")
        }
        return nil
    }

    /// Patterns are matched against `host + path` so the same domain can serve both kinds
    /// of content — `youtube.com/watch` is a video, `music.youtube.com` is not.
    /// URL host boundaries are strictly enforced: bare-domain patterns match only that
    /// exact host or its subdomains, preventing deceptive suffixes (e.g. evilvimeo.com
    /// cannot match vimeo.com).
    static func matches(_ urlString: String, _ patterns: [String]) -> Bool {
        guard let components = urlComponents(from: urlString),
              let rawHost = components.host else { return false }
        let urlHost = rawHost.lowercased()
        let urlPath = components.path.lowercased()

        return patterns.contains { pattern in
            matchesPattern(urlHost: urlHost, urlPath: urlPath, pattern: pattern)
        }
    }

    private static func urlComponents(from urlString: String) -> URLComponents? {
        if let comps = URLComponents(string: urlString), comps.host != nil {
            return comps
        }
        return URLComponents(string: "https://" + urlString)
    }

    static func matchesPattern(urlHost: String, urlPath: String, pattern: String) -> Bool {
        var p = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let schemeRange = p.range(of: "://") {
            p = String(p[schemeRange.upperBound...])
        }
        while p.hasPrefix("/") {
            p.removeFirst()
        }
        guard !p.isEmpty else { return false }

        let parts = p.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let patternHost = String(parts[0])
        let patternPath = parts.count > 1 ? String(parts[1]) : ""

        // Host matching: bare-domain patterns must match exactly or as a subdomain.
        // e.g. "vimeo.com" matches "vimeo.com" and "www.vimeo.com", but NEVER "evilvimeo.com".
        let hostMatches = urlHost == patternHost || urlHost.hasSuffix("." + patternHost)
        guard hostMatches else { return false }

        // Path matching:
        // If pattern has no path or empty path (e.g. "meet.google.com/"), any path on this host matches.
        if patternPath.isEmpty {
            return true
        }

        let normalizedPatternPath = "/" + patternPath
        let normalizedURLPath = urlPath.isEmpty ? "/" : urlPath

        if pattern.hasSuffix("/") {
            return normalizedURLPath == normalizedPatternPath
                || normalizedURLPath.hasPrefix(normalizedPatternPath.hasSuffix("/") ? normalizedPatternPath : normalizedPatternPath + "/")
        } else {
            return normalizedURLPath == normalizedPatternPath
                || normalizedURLPath.hasPrefix(normalizedPatternPath + "/")
        }
    }

    static func isBrowserSupported(bundleID: String) -> Bool {
        Dialect(bundleID: bundleID) != nil
    }

    // MARK: - AppleScript

    private func runScript(_ source: String, error: inout String?) -> [String]? {
        guard let script = NSAppleScript(source: source) else {
            error = "could not compile AppleScript"
            return nil
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
            // -1743 is "not authorized to send Apple events" — the Automation permission
            // has not been granted (or was reset by a change of code signature).
            error = number == -1743
                ? "Automation permission not granted (error -1743)"
                : "AppleScript error \(number): \(message)"
            return nil
        }

        return descriptorToStrings(result)
    }

    private func descriptorToStrings(_ descriptor: NSAppleEventDescriptor) -> [String] {
        // A list descriptor is 1-indexed; a single value comes back bare.
        guard descriptor.numberOfItems > 0 else {
            return descriptor.stringValue.map { [$0] } ?? []
        }
        return (1...descriptor.numberOfItems).compactMap { index in
            let item = descriptor.atIndex(index)
            if item?.numberOfItems ?? 0 > 0 {
                return descriptorToStrings(item!).first  // nested per-window lists
            }
            return item?.stringValue
        }
    }

    // MARK: - Per-browser scripting differences

    /// Chrome says `active tab`, Safari says `current tab`. Same idea, different nouns.
    private enum Dialect {
        case chromium(appName: String)
        case safari

        init?(bundleID: String) {
            switch bundleID {
            case "com.google.Chrome":           self = .chromium(appName: "Google Chrome")
            case "com.brave.Browser":           self = .chromium(appName: "Brave Browser")
            case "company.thebrowser.Browser":  self = .chromium(appName: "Arc")
            case "com.microsoft.edgemac":       self = .chromium(appName: "Microsoft Edge")
            case "com.apple.Safari":            self = .safari
            default:                            return nil
            }
        }

        var activeTabScript: String {
            switch self {
            case .chromium(let appName):
                return """
                tell application "\(appName)"
                    if (count of windows) is 0 then return ""
                    return URL of active tab of front window
                end tell
                """
            case .safari:
                return """
                tell application "Safari"
                    if (count of windows) is 0 then return ""
                    return URL of current tab of front window
                end tell
                """
            }
        }

        /// The *active* tab of every window — not every tab of every window.
        ///
        /// Scanning all tabs proved useless in practice: on a real machine with 72 tabs
        /// open, five long-lived phish.in tabs meant the fallback always saw music and
        /// always suppressed, so the branch never fired.
        ///
        /// Per-window active tabs is both far cheaper and a better model of reality —
        /// audio almost always comes from the tab that's frontmost in its own window.
        /// A truly buried background tab that autoplays with sound is rare, and missing
        /// it only costs a prompt.
        var windowActiveTabsScript: String {
            switch self {
            case .chromium(let appName):
                return """
                tell application "\(appName)"
                    set urlList to {}
                    repeat with w in windows
                        try
                            set end of urlList to URL of active tab of w
                        end try
                    end repeat
                    return urlList
                end tell
                """
            case .safari:
                return """
                tell application "Safari"
                    set urlList to {}
                    repeat with w in windows
                        try
                            set end of urlList to URL of current tab of w
                        end try
                    end repeat
                    return urlList
                end tell
                """
            }
        }
    }
}
