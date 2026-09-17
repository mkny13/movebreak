import Foundation

/// User-tunable configuration, backed by UserDefaults so the bundle-ID and URL lists can
/// be adjusted without a rebuild:
///
///     defaults write com.mike.movebreak musicPatterns -array "relisten.net" "phish.in"
///
/// Every list has a built-in default; writing a key overrides it wholesale.
/// All user-supplied inputs are strictly validated and normalized against explicit bounds
/// to ensure safe operation.
enum Preferences {
    static var defaults: UserDefaults = .standard

    // MARK: - Bounds and Limits

    static let maxListCount = 100
    static let maxItemLength = 256

    static let defaultPollInterval: TimeInterval = 2.0
    static let pollIntervalRange: ClosedRange<TimeInterval> = 0.5...60.0

    static let defaultDebouncePolls: Int = 2
    static let debouncePollsRange: ClosedRange<Int> = 1...20

    static let defaultSessionEndGrace: TimeInterval = 60.0
    static let sessionEndGraceRange: ClosedRange<TimeInterval> = 5.0...600.0

    static let defaultDeclineCooldown: TimeInterval = 45 * 60  // 2700s (45m)
    static let declineCooldownRange: ClosedRange<TimeInterval> = 60.0...86400.0

    static let defaultTimeoutCooldown: TimeInterval = 15 * 60  // 900s (15m)
    static let timeoutCooldownRange: ClosedRange<TimeInterval> = 60.0...86400.0

    static let defaultPromptTimeout: TimeInterval = 30.0
    static let promptTimeoutRange: ClosedRange<TimeInterval> = 5.0...300.0

    static let defaultTabCacheLifetime: TimeInterval = 5.0
    static let tabCacheLifetimeRange: ClosedRange<TimeInterval> = 1.0...60.0

    // MARK: - Built-in Defaults

    static let defaultMeetingApps: Set<String> = [
        "us.zoom.xos",                  // Zoom main app
        "us.zoom.CptHost",              // Zoom meeting host helper (version dependent)
        "us.zoom.aomhost",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.cisco.webexmeetingsapp",
        "com.apple.FaceTime",
        "com.tinyspeck.slackmacgap",    // Slack huddles
        "com.hnc.Discord",
    ]

    static let defaultNativePlayers: Set<String> = [
        "com.apple.QuickTimePlayerX",
        "org.videolan.vlc",
        "com.colliderli.iina",
    ]

    /// Fixed supported browser bundle IDs that have AppleScript tab reading support.
    /// Internal permission boundary: arbitrary application identifiers can never expand
    /// AppleScript targeting beyond this fixed allowlist.
    static let supportedBrowsers: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.brave.Browser",
        "company.thebrowser.Browser",   // Arc
        "com.microsoft.edgemac",
    ]

    static let defaultBrowsers: Set<String> = supportedBrowsers

    static let defaultIgnoredApps: Set<String> = [
        "com.spotify.client",
        "com.apple.Music",
    ]

    static let defaultMeetingPatterns: [String] = [
        "meet.google.com/",
        "teams.microsoft.com/",
        "teams.live.com/",
        "zoom.us/wc",
        "zoom.us/j/",
        "whereby.com/",
        "webex.com/meet",
        "app.slack.com/huddle",
        "discord.com/channels",
    ]

    static let defaultVideoPatterns: [String] = [
        "youtube.com/watch",
        "youtube.com/shorts",
        "youtube.com/live",
        "vimeo.com",
        "netflix.com/watch",
        "twitch.tv",
        "hulu.com/watch",
        "max.com/video",
        "disneyplus.com/video",
        "coursera.org/lecture",
        "udemy.com/course",
    ]

    static let defaultMusicPatterns: [String] = [
        "music.youtube.com",
        "relisten.net",
        "phish.in",
        "siriusxm.com",
        "player.siriusxm.com",
        "bandcamp.com",
        "soundcloud.com",
        "open.spotify.com",
        "music.apple.com",
        "archive.org/details",          // Relisten's backing source
        "nugs.net",
        "mixcloud.com",
    ]

    // MARK: - Bundle ID lists

    /// A live *microphone* stream from one of these means "in a call". This is the
    /// unambiguous signal — no URL inspection needed for any of them.
    static var meetingApps: Set<String> {
        bundleIDSet(forKey: "meetingApps", default: defaultMeetingApps).union(browsers)
    }

    /// A live *output* stream from one of these means "watching video", no questions asked.
    static var nativePlayers: Set<String> {
        bundleIDSet(forKey: "nativePlayers", default: defaultNativePlayers)
    }

    /// Output from these needs a URL check before we can call it video vs music.
    /// Constrained to `supportedBrowsers` to guarantee AppleScript targets cannot be hijacked.
    static var browsers: Set<String> {
        let configured = bundleIDSet(forKey: "browsers", default: defaultBrowsers)
        let allowed = configured.intersection(supportedBrowsers)
        return allowed.isEmpty ? defaultBrowsers : allowed
    }

    /// Never counts as a sedentary session, regardless of stream state.
    static var ignoredApps: Set<String> {
        bundleIDSet(forKey: "ignoredApps", default: defaultIgnoredApps)
    }

    // MARK: - URL patterns

    /// Browser-based calls. Checked before video and music, and the reason Google Meet
    /// works even when you're muted: unlike Zoom, Chrome releases the microphone stream
    /// when a Meet call is muted, so the mic signal in stage 1 disappears and only the
    /// URL identifies the call.
    static var meetingPatterns: [String] {
        patternList(forKey: "meetingPatterns", default: defaultMeetingPatterns)
    }

    /// Matched against `host + path`, because the same domain serves both kinds of
    /// content (youtube.com/watch is video, music.youtube.com is not).
    static var videoPatterns: [String] {
        patternList(forKey: "videoPatterns", default: defaultVideoPatterns)
    }

    static var musicPatterns: [String] {
        patternList(forKey: "musicPatterns", default: defaultMusicPatterns)
    }

    // MARK: - Timing

    /// How often to sample the audio process list.
    static var pollInterval: TimeInterval {
        double(forKey: "pollInterval", default: defaultPollInterval, range: pollIntervalRange)
    }

    /// Consecutive matching polls required before a state change is believed. Filters out
    /// notification chirps and UI sounds, which open an output stream for well under this.
    static var debouncePolls: Int {
        int(forKey: "debouncePolls", default: defaultDebouncePolls, range: debouncePollsRange)
    }

    /// How long the state must stay idle before the session is considered over.
    static var sessionEndGrace: TimeInterval {
        double(forKey: "sessionEndGrace", default: defaultSessionEndGrace, range: sessionEndGraceRange)
    }

    /// Suppression after an explicit "Not now".
    static var declineCooldown: TimeInterval {
        double(forKey: "declineCooldown", default: defaultDeclineCooldown, range: declineCooldownRange)
    }

    /// Suppression after the prompt times out unanswered (softer than an explicit decline).
    static var timeoutCooldown: TimeInterval {
        double(forKey: "timeoutCooldown", default: defaultTimeoutCooldown, range: timeoutCooldownRange)
    }

    /// How long the prompt waits before giving up.
    static var promptTimeout: TimeInterval {
        double(forKey: "promptTimeout", default: defaultPromptTimeout, range: promptTimeoutRange)
    }

    /// Cache lifetime for AppleScript tab reads, so a 2s poll doesn't spam Apple Events.
    static var tabCacheLifetime: TimeInterval {
        double(forKey: "tabCacheLifetime", default: defaultTabCacheLifetime, range: tabCacheLifetimeRange)
    }

    // MARK: - Notion

    /// Not a secret — the integration token lives in the Keychain instead. Set via
    /// `--configure-notion`.
    static var notionDatabaseID: String? {
        get { defaults.string(forKey: "notionDatabaseID") }
        set { defaults.set(newValue, forKey: "notionDatabaseID") }
    }

    // MARK: - Test Support

    /// Executes a closure using a temporary isolated UserDefaults domain, restoring the previous
    /// defaults suite when finished.
    @discardableResult
    static func withDefaults<T>(_ testDefaults: UserDefaults, perform: () throws -> T) rethrows -> T {
        let previous = defaults
        defaults = testDefaults
        defer { defaults = previous }
        return try perform()
    }

    // MARK: - Normalization & Validation

    /// Normalizes bundle identifier lists: trims whitespace, drops empty/oversized/invalid
    /// entries, deduplicates deterministically preserving order, and caps at `maxListCount`.
    static func normalizeBundleIDs(_ rawItems: [Any]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let validChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))

        for item in rawItems {
            guard let str = item as? String else { continue }
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.count <= maxItemLength,
                  trimmed.unicodeScalars.allSatisfy({ validChars.contains($0) }) else {
                continue
            }
            if seen.insert(trimmed).inserted {
                result.append(trimmed)
                if result.count >= maxListCount {
                    break
                }
            }
        }
        return result
    }

    /// Normalizes URL pattern lists: trims whitespace, strips schemes/leading slashes, drops
    /// empty/oversized/malformed entries, deduplicates deterministically, and caps at `maxListCount`.
    static func normalizeURLPatterns(_ rawItems: [Any]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let validHostChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))

        for item in rawItems {
            guard let str = item as? String else { continue }
            var trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= maxItemLength else { continue }

            if let schemeRange = trimmed.range(of: "://") {
                trimmed = String(trimmed[schemeRange.upperBound...])
            }
            while trimmed.hasPrefix("/") {
                trimmed.removeFirst()
            }
            guard !trimmed.isEmpty else { continue }

            let hostPart = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
            guard !hostPart.isEmpty,
                  hostPart.unicodeScalars.allSatisfy({ validHostChars.contains($0) }),
                  !trimmed.contains(" ") else {
                continue
            }

            let normalized = trimmed.lowercased()
            if seen.insert(normalized).inserted {
                result.append(normalized)
                if result.count >= maxListCount {
                    break
                }
            }
        }
        return result
    }

    // MARK: - Accessors

    private static func bundleIDSet(forKey key: String, default fallback: Set<String>) -> Set<String> {
        guard let stored = defaults.array(forKey: key) else {
            return fallback
        }
        let normalized = normalizeBundleIDs(stored)
        return normalized.isEmpty ? fallback : Set(normalized)
    }

    private static func patternList(forKey key: String, default fallback: [String]) -> [String] {
        guard let stored = defaults.array(forKey: key) else {
            return fallback
        }
        let normalized = normalizeURLPatterns(stored)
        return normalized.isEmpty ? fallback : normalized
    }

    private static func double(
        forKey key: String,
        default fallback: TimeInterval,
        range: ClosedRange<TimeInterval>
    ) -> TimeInterval {
        guard let object = defaults.object(forKey: key) else { return fallback }
        let value: Double
        if let num = object as? NSNumber {
            value = num.doubleValue
        } else if let str = object as? String,
                  let parsed = Double(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
            value = parsed
        } else {
            return fallback
        }
        guard value.isFinite, value > 0, range.contains(value) else {
            return fallback
        }
        return value
    }

    private static func int(
        forKey key: String,
        default fallback: Int,
        range: ClosedRange<Int>
    ) -> Int {
        guard let object = defaults.object(forKey: key) else { return fallback }
        let value: Int
        if let num = object as? NSNumber {
            value = num.intValue
        } else if let str = object as? String,
                  let parsed = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
            value = parsed
        } else {
            return fallback
        }
        guard range.contains(value) else {
            return fallback
        }
        return value
    }
}
