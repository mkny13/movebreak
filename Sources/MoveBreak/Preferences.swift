import Foundation

/// User-tunable configuration, backed by UserDefaults so the bundle-ID and URL lists can
/// be adjusted without a rebuild:
///
///     defaults write com.mike.movebreak musicPatterns -array "relisten.net" "phish.in"
///
/// Every list has a built-in default; writing a key overrides it wholesale.
enum Preferences {
    private static let defaults = UserDefaults.standard

    // MARK: - Bundle ID lists

    /// A live *microphone* stream from one of these means "in a call". This is the
    /// unambiguous signal — no URL inspection needed for any of them.
    static var meetingApps: Set<String> {
        stringSet(forKey: "meetingApps", default: [
            "us.zoom.xos",                  // Zoom main app
            "us.zoom.CptHost",              // Zoom meeting host helper (version dependent)
            "us.zoom.aomhost",
            "com.microsoft.teams2",
            "com.microsoft.teams",
            "com.cisco.webexmeetingsapp",
            "com.apple.FaceTime",
            "com.tinyspeck.slackmacgap",    // Slack huddles
            "com.hnc.Discord",
        ]).union(browsers)                  // Meet/Whereby/etc. run in a browser
    }

    /// A live *output* stream from one of these means "watching video", no questions asked.
    static var nativePlayers: Set<String> {
        stringSet(forKey: "nativePlayers", default: [
            "com.apple.QuickTimePlayerX",
            "org.videolan.vlc",
            "com.colliderli.iina",
        ])
    }

    /// Output from these needs a URL check before we can call it video vs music.
    static var browsers: Set<String> {
        stringSet(forKey: "browsers", default: [
            "com.google.Chrome",
            "com.apple.Safari",
            "com.brave.Browser",
            "company.thebrowser.Browser",   // Arc
            "com.microsoft.edgemac",
            // Firefox is deliberately absent: it exposes no AppleScript tab API at all,
            // so we could never classify it. Adding it here would only ever produce
            // unclassifiable output and, per the bias below, get ignored anyway.
        ])
    }

    /// Never counts as a sedentary session, regardless of stream state.
    static var ignoredApps: Set<String> {
        stringSet(forKey: "ignoredApps", default: [
            "com.spotify.client",
            "com.apple.Music",
        ])
    }

    // MARK: - URL patterns

    /// Browser-based calls. Checked before video and music, and the reason Google Meet
    /// works even when you're muted: unlike Zoom, Chrome releases the microphone stream
    /// when a Meet call is muted, so the mic signal in stage 1 disappears and only the
    /// URL identifies the call.
    static var meetingPatterns: [String] {
        list(forKey: "meetingPatterns", default: [
            "meet.google.com/",
            "teams.microsoft.com/",
            "teams.live.com/",
            "zoom.us/wc",
            "zoom.us/j/",
            "whereby.com/",
            "webex.com/meet",
            "app.slack.com/huddle",
            "discord.com/channels",
        ])
    }

    /// Matched against `host + path`, because the same domain serves both kinds of
    /// content (youtube.com/watch is video, music.youtube.com is not).
    static var videoPatterns: [String] {
        list(forKey: "videoPatterns", default: [
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
        ])
    }

    static var musicPatterns: [String] {
        list(forKey: "musicPatterns", default: [
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
        ])
    }

    // MARK: - Timing

    /// How often to sample the audio process list.
    static var pollInterval: TimeInterval { double(forKey: "pollInterval", default: 2.0) }

    /// Consecutive matching polls required before a state change is believed. Filters out
    /// notification chirps and UI sounds, which open an output stream for well under this.
    static var debouncePolls: Int { int(forKey: "debouncePolls", default: 2) }

    /// How long the state must stay idle before the session is considered over.
    static var sessionEndGrace: TimeInterval { double(forKey: "sessionEndGrace", default: 60) }

    /// Suppression after an explicit "Not now".
    static var declineCooldown: TimeInterval { double(forKey: "declineCooldown", default: 45 * 60) }

    /// Suppression after the prompt times out unanswered (softer than an explicit decline).
    static var timeoutCooldown: TimeInterval { double(forKey: "timeoutCooldown", default: 15 * 60) }

    /// How long the prompt waits before giving up.
    static var promptTimeout: TimeInterval { double(forKey: "promptTimeout", default: 30) }

    /// Cache lifetime for AppleScript tab reads, so a 2s poll doesn't spam Apple Events.
    static var tabCacheLifetime: TimeInterval { double(forKey: "tabCacheLifetime", default: 5.0) }

    // MARK: - Notion

    /// Not a secret — the integration token lives in the Keychain instead. Set via
    /// `--configure-notion`.
    static var notionDatabaseID: String? {
        get { defaults.string(forKey: "notionDatabaseID") }
        set { defaults.set(newValue, forKey: "notionDatabaseID") }
    }

    // MARK: - Accessors

    private static func stringSet(forKey key: String, default fallback: Set<String>) -> Set<String> {
        guard let stored = defaults.array(forKey: key) as? [String], !stored.isEmpty else {
            return fallback
        }
        return Set(stored)
    }

    private static func list(forKey key: String, default fallback: [String]) -> [String] {
        guard let stored = defaults.array(forKey: key) as? [String], !stored.isEmpty else {
            return fallback
        }
        return stored
    }

    private static func double(forKey key: String, default fallback: TimeInterval) -> TimeInterval {
        defaults.object(forKey: key) as? TimeInterval ?? fallback
    }

    private static func int(forKey key: String, default fallback: Int) -> Int {
        defaults.object(forKey: key) as? Int ?? fallback
    }
}
