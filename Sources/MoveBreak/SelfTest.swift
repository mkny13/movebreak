import Foundation

/// Exercises the video-vs-music rules, configuration boundaries, denial-list enforcement,
/// and security boundaries directly, with no browser and no Automation grant.
///
/// Run with:  ./build/MoveBreak --self-test
enum SelfTest {

    /// Guards the bug that made stage 3 silently dead: audio is reported against helper
    /// processes, not the app itself, so `com.google.Chrome.helper` must resolve to
    /// `com.google.Chrome`. Observed live on a real machine — Chrome playback never
    /// reports as `com.google.Chrome`.
    private static func runIdentityCases() -> Int {
        let browsers = Preferences.browsers
        let meetings = Preferences.meetingApps

        let cases: [(process: String, set: Set<String>, expected: String?)] = [
            ("com.google.Chrome.helper",           browsers, "com.google.Chrome"),
            ("com.google.Chrome.helper.Renderer",  browsers, "com.google.Chrome"),
            ("com.google.Chrome",                  browsers, "com.google.Chrome"),
            ("com.apple.WebKit.GPU",               browsers, "com.apple.Safari"),
            ("com.apple.WebKit.WebContent",        browsers, "com.apple.Safari"),
            ("com.brave.Browser.helper",           browsers, "com.brave.Browser"),
            ("com.tinyspeck.slackmacgap.helper",   meetings, "com.tinyspeck.slackmacgap"),
            ("us.zoom.xos",                        meetings, "us.zoom.xos"),
            ("com.apple.Music",                    browsers, nil),
            ("com.google.ChromeSomethingElse",     browsers, nil),  // must not prefix-match
        ]

        var failures = 0
        for testCase in cases {
            let actual = BundleIdentity.owner(of: testCase.process, in: testCase.set)
            let passed = actual == testCase.expected
            if !passed { failures += 1 }
            print("\(passed ? "✓" : "✗ FAIL")  \(testCase.process)")
            if !passed {
                print("      expected \(testCase.expected ?? "no match"), got \(actual ?? "no match")")
            }
        }
        return failures
    }

    private struct Case {
        let name: String
        let activeURL: String?
        let allURLs: [String]
        let expectVideo: Bool
        let expectMeeting: Bool

        init(name: String, activeURL: String?, allURLs: [String],
             expectVideo: Bool = false, expectMeeting: Bool = false) {
            self.name = name
            self.activeURL = activeURL
            self.allURLs = allURLs
            self.expectVideo = expectVideo
            self.expectMeeting = expectMeeting
        }
    }

    /// Catches two ways the catalog/seed split could silently break: two exercises
    /// slugging to the same id (the picker couldn't tell them apart), or a default seed
    /// referencing a name that doesn't match anything in the catalog (it would just
    /// vanish from "Do PT" etc. with no error).
    private static func runCatalogCases() -> Int {
        var failures = 0

        var seen: Set<String> = []
        for exercise in ExerciseCatalog.all {
            if seen.contains(exercise.id) {
                failures += 1
                print("✗ FAIL  duplicate catalog id \"\(exercise.id)\" (from \"\(exercise.name)\")")
            }
            seen.insert(exercise.id)
        }
        if failures == 0 {
            print("✓  \(ExerciseCatalog.all.count) catalog exercises, all ids unique")
        }

        for seed in RoutineStore.defaultSeeds {
            let missing = seed.exerciseIDs.filter { ExerciseCatalog.exercise(id: $0) == nil }
            if missing.isEmpty {
                print("✓  seed \"\(seed.name)\" resolves all \(seed.exerciseIDs.count) picks")
            } else {
                failures += 1
                print("✗ FAIL  seed \"\(seed.name)\" has ids missing from the catalog: \(missing)")
            }
        }

        return failures
    }

    // MARK: - Numeric Preferences Regression Cases

    private static func runNumericPreferencesCases() -> Int {
        var failures = 0
        let suiteName = "com.mike.movebreak.tests.numeric.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            print("✗ FAIL  could not instantiate isolated UserDefaults suite")
            return 1
        }
        defer {
            testDefaults.removePersistentDomain(forName: suiteName)
        }

        func check<T: Equatable>(_ name: String, expected: T, actual: T) {
            let passed = expected == actual
            if !passed { failures += 1 }
            print("\(passed ? "✓" : "✗ FAIL")  \(name)")
            if !passed {
                print("      expected \(expected), got \(actual)")
            }
        }

        Preferences.withDefaults(testDefaults) {
            // Unconfigured values fall back to documented safe defaults
            check("default pollInterval", expected: Preferences.defaultPollInterval, actual: Preferences.pollInterval)
            check("default debouncePolls", expected: Preferences.defaultDebouncePolls, actual: Preferences.debouncePolls)
            check("default sessionEndGrace", expected: Preferences.defaultSessionEndGrace, actual: Preferences.sessionEndGrace)
            check("default declineCooldown", expected: Preferences.defaultDeclineCooldown, actual: Preferences.declineCooldown)
            check("default timeoutCooldown", expected: Preferences.defaultTimeoutCooldown, actual: Preferences.timeoutCooldown)
            check("default promptTimeout", expected: Preferences.defaultPromptTimeout, actual: Preferences.promptTimeout)
            check("default tabCacheLifetime", expected: Preferences.defaultTabCacheLifetime, actual: Preferences.tabCacheLifetime)

            // pollInterval bounds [0.5 ... 60.0]
            testDefaults.set(-1.0, forKey: "pollInterval")
            check("pollInterval negative falls back", expected: Preferences.defaultPollInterval, actual: Preferences.pollInterval)
            testDefaults.set(0.0, forKey: "pollInterval")
            check("pollInterval zero falls back", expected: Preferences.defaultPollInterval, actual: Preferences.pollInterval)
            testDefaults.set(0.1, forKey: "pollInterval")
            check("pollInterval below min (0.1) falls back", expected: Preferences.defaultPollInterval, actual: Preferences.pollInterval)
            testDefaults.set(100.0, forKey: "pollInterval")
            check("pollInterval above max (100.0) falls back", expected: Preferences.defaultPollInterval, actual: Preferences.pollInterval)
            testDefaults.set(Double.nan, forKey: "pollInterval")
            check("pollInterval NaN falls back", expected: Preferences.defaultPollInterval, actual: Preferences.pollInterval)
            testDefaults.set(Double.infinity, forKey: "pollInterval")
            check("pollInterval +Inf falls back", expected: Preferences.defaultPollInterval, actual: Preferences.pollInterval)
            testDefaults.set(-Double.infinity, forKey: "pollInterval")
            check("pollInterval -Inf falls back", expected: Preferences.defaultPollInterval, actual: Preferences.pollInterval)
            testDefaults.set("not-a-number", forKey: "pollInterval")
            check("pollInterval malformed string falls back", expected: Preferences.defaultPollInterval, actual: Preferences.pollInterval)
            testDefaults.set(5.0, forKey: "pollInterval")
            check("pollInterval valid in-range accepted", expected: 5.0, actual: Preferences.pollInterval)

            // debouncePolls bounds [1 ... 20]
            testDefaults.set(0, forKey: "debouncePolls")
            check("debouncePolls zero falls back", expected: Preferences.defaultDebouncePolls, actual: Preferences.debouncePolls)
            testDefaults.set(-5, forKey: "debouncePolls")
            check("debouncePolls negative falls back", expected: Preferences.defaultDebouncePolls, actual: Preferences.debouncePolls)
            testDefaults.set(50, forKey: "debouncePolls")
            check("debouncePolls above max falls back", expected: Preferences.defaultDebouncePolls, actual: Preferences.debouncePolls)
            testDefaults.set("invalid", forKey: "debouncePolls")
            check("debouncePolls invalid string falls back", expected: Preferences.defaultDebouncePolls, actual: Preferences.debouncePolls)
            testDefaults.set(4, forKey: "debouncePolls")
            check("debouncePolls valid accepted", expected: 4, actual: Preferences.debouncePolls)

            // sessionEndGrace bounds [5.0 ... 600.0]
            testDefaults.set(0.0, forKey: "sessionEndGrace")
            check("sessionEndGrace zero falls back", expected: Preferences.defaultSessionEndGrace, actual: Preferences.sessionEndGrace)
            testDefaults.set(2.0, forKey: "sessionEndGrace")
            check("sessionEndGrace below min falls back", expected: Preferences.defaultSessionEndGrace, actual: Preferences.sessionEndGrace)
            testDefaults.set(1000.0, forKey: "sessionEndGrace")
            check("sessionEndGrace above max falls back", expected: Preferences.defaultSessionEndGrace, actual: Preferences.sessionEndGrace)
            testDefaults.set(120.0, forKey: "sessionEndGrace")
            check("sessionEndGrace valid accepted", expected: 120.0, actual: Preferences.sessionEndGrace)

            // declineCooldown bounds [60.0 ... 86400.0]
            testDefaults.set(10.0, forKey: "declineCooldown")
            check("declineCooldown below min falls back", expected: Preferences.defaultDeclineCooldown, actual: Preferences.declineCooldown)
            testDefaults.set(200000.0, forKey: "declineCooldown")
            check("declineCooldown above max falls back", expected: Preferences.defaultDeclineCooldown, actual: Preferences.declineCooldown)
            testDefaults.set(1800.0, forKey: "declineCooldown")
            check("declineCooldown valid accepted", expected: 1800.0, actual: Preferences.declineCooldown)

            // timeoutCooldown bounds [60.0 ... 86400.0]
            testDefaults.set(-10.0, forKey: "timeoutCooldown")
            check("timeoutCooldown negative falls back", expected: Preferences.defaultTimeoutCooldown, actual: Preferences.timeoutCooldown)
            testDefaults.set(600.0, forKey: "timeoutCooldown")
            check("timeoutCooldown valid accepted", expected: 600.0, actual: Preferences.timeoutCooldown)

            // promptTimeout bounds [5.0 ... 300.0]
            testDefaults.set(1.0, forKey: "promptTimeout")
            check("promptTimeout below min falls back", expected: Preferences.defaultPromptTimeout, actual: Preferences.promptTimeout)
            testDefaults.set(500.0, forKey: "promptTimeout")
            check("promptTimeout above max falls back", expected: Preferences.defaultPromptTimeout, actual: Preferences.promptTimeout)
            testDefaults.set(45.0, forKey: "promptTimeout")
            check("promptTimeout valid accepted", expected: 45.0, actual: Preferences.promptTimeout)

            // tabCacheLifetime bounds [1.0 ... 60.0]
            testDefaults.set(0.1, forKey: "tabCacheLifetime")
            check("tabCacheLifetime below min falls back", expected: Preferences.defaultTabCacheLifetime, actual: Preferences.tabCacheLifetime)
            testDefaults.set(120.0, forKey: "tabCacheLifetime")
            check("tabCacheLifetime above max falls back", expected: Preferences.defaultTabCacheLifetime, actual: Preferences.tabCacheLifetime)
            testDefaults.set(10.0, forKey: "tabCacheLifetime")
            check("tabCacheLifetime valid accepted", expected: 10.0, actual: Preferences.tabCacheLifetime)
        }

        return failures
    }

    // MARK: - List Normalization Regression Cases

    private static func runListNormalizationCases() -> Int {
        var failures = 0
        let suiteName = "com.mike.movebreak.tests.list.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            print("✗ FAIL  could not instantiate isolated UserDefaults suite")
            return 1
        }
        defer {
            testDefaults.removePersistentDomain(forName: suiteName)
        }

        func check<T: Equatable>(_ name: String, expected: T, actual: T) {
            let passed = expected == actual
            if !passed { failures += 1 }
            print("\(passed ? "✓" : "✗ FAIL")  \(name)")
            if !passed {
                print("      expected \(expected), got \(actual)")
            }
        }

        Preferences.withDefaults(testDefaults) {
            // Empty array falls back to default
            testDefaults.set([] as [String], forKey: "videoPatterns")
            check("empty list falls back", expected: Preferences.defaultVideoPatterns, actual: Preferences.videoPatterns)

            // Array of blanks falls back to default
            testDefaults.set(["", "   ", "\t\n"], forKey: "videoPatterns")
            check("blanks list falls back", expected: Preferences.defaultVideoPatterns, actual: Preferences.videoPatterns)

            // Oversized entries (> 256 chars) dropped
            let oversized = String(repeating: "a", count: 300)
            testDefaults.set([oversized], forKey: "videoPatterns")
            check("oversized entries list falls back", expected: Preferences.defaultVideoPatterns, actual: Preferences.videoPatterns)

            // Trimming, scheme stripping, deduplication preserving order
            testDefaults.set([
                "  https://vimeo.com  ",
                "twitch.tv",
                "vimeo.com",
                "   ",
                "http://coursera.org/lecture",
                "twitch.tv",
            ], forKey: "videoPatterns")
            check(
                "deduplication and trimming of URL patterns",
                expected: ["vimeo.com", "twitch.tv", "coursera.org/lecture"],
                actual: Preferences.videoPatterns
            )

            // Cap at maxListCount (100)
            let many = (1...150).map { "site\($0).org/video" }
            testDefaults.set(many, forKey: "videoPatterns")
            check("capped at maxListCount (100)", expected: Preferences.maxListCount, actual: Preferences.videoPatterns.count)

            // Bundle ID normalization: trim, drop invalid characters/spaces, deduplicate
            testDefaults.set([
                "",
                "  com.custom.app  ",
                "com.custom.app",
                "invalid bundle with spaces",
                "invalid/bundle",
                oversized,
            ], forKey: "ignoredApps")
            check(
                "bundle ID normalization and invalid character dropping",
                expected: Set(["com.custom.app"]),
                actual: Preferences.ignoredApps
            )
        }

        return failures
    }

    // MARK: - URL Host Boundary Regression Cases

    private static func runHostBoundaryCases() -> Int {
        var failures = 0

        func checkMatch(_ url: String, pattern: String, expected: Bool, name: String) {
            let actual = BrowserTabInspector.matches(url, [pattern])
            let passed = actual == expected
            if !passed { failures += 1 }
            print("\(passed ? "✓" : "✗ FAIL")  \(name)")
            if !passed {
                print("      URL: \(url), pattern: \(pattern), expected \(expected), got \(actual)")
            }
        }

        // Bare domain: vimeo.com
        checkMatch("https://vimeo.com/12345", pattern: "vimeo.com", expected: true, name: "exact host match")
        checkMatch("https://www.vimeo.com/12345", pattern: "vimeo.com", expected: true, name: "subdomain matches bare domain")
        checkMatch("https://player.vimeo.com/video/1", pattern: "vimeo.com", expected: true, name: "deep subdomain matches bare domain")
        checkMatch("https://evilvimeo.com/12345", pattern: "vimeo.com", expected: false, name: "deceptive prefix evilvimeo.com rejected")
        checkMatch("https://notvimeo.com/12345", pattern: "vimeo.com", expected: false, name: "notvimeo.com rejected")
        checkMatch("https://vimeo.com.attacker.com/12345", pattern: "vimeo.com", expected: false, name: "deceptive suffix attacker.com rejected")

        // Bare domain: twitch.tv
        checkMatch("https://twitch.tv/streamer", pattern: "twitch.tv", expected: true, name: "twitch.tv matches")
        checkMatch("https://www.twitch.tv/streamer", pattern: "twitch.tv", expected: true, name: "www.twitch.tv matches")
        checkMatch("https://faketwitch.tv/streamer", pattern: "twitch.tv", expected: false, name: "faketwitch.tv rejected")

        // Host + path: youtube.com/watch
        checkMatch("https://www.youtube.com/watch?v=123", pattern: "youtube.com/watch", expected: true, name: "youtube.com/watch matches")
        checkMatch("https://youtube.com/watch?v=123", pattern: "youtube.com/watch", expected: true, name: "bare youtube.com/watch matches")
        checkMatch("https://evilyoutube.com/watch?v=123", pattern: "youtube.com/watch", expected: false, name: "evilyoutube.com/watch rejected")
        checkMatch("https://youtube.com.attacker.com/watch", pattern: "youtube.com/watch", expected: false, name: "youtube.com.attacker.com/watch rejected")
        checkMatch("https://www.youtube.com/watchlist", pattern: "youtube.com/watch", expected: false, name: "watchlist does not match watch segment")
        checkMatch("https://www.youtube.com/watch_video", pattern: "youtube.com/watch", expected: false, name: "watch_video does not match watch")
        checkMatch("https://www.youtube.com/", pattern: "youtube.com/watch", expected: false, name: "youtube homepage does not match watch")

        // Host + path: zoom.us/wc
        checkMatch("https://us02web.zoom.us/wc/join/123", pattern: "zoom.us/wc", expected: true, name: "zoom.us/wc subpath matches")
        checkMatch("https://evilzoom.us/wc/join/123", pattern: "zoom.us/wc", expected: false, name: "evilzoom.us rejected")
        checkMatch("https://us02web.zoom.us/wcfake", pattern: "zoom.us/wc", expected: false, name: "wcfake path rejected")

        // Bare domain with slash: meet.google.com/
        checkMatch("https://meet.google.com/abc-defg-hij", pattern: "meet.google.com/", expected: true, name: "meet.google.com/ matches meet call")
        checkMatch("https://evilmeet.google.com/abc", pattern: "meet.google.com/", expected: false, name: "evilmeet.google.com rejected")
        checkMatch("https://mail.google.com/", pattern: "meet.google.com/", expected: false, name: "mail.google.com rejected")

        return failures
    }

    // MARK: - Ignored Apps Precedence Regression Cases

    private static func runIgnoredAppsPrecedenceCases() -> Int {
        var failures = 0

        func check(
            name: String,
            processes: [AudioProcess],
            ignoredApps: Set<String>,
            meetingApps: Set<String> = Preferences.defaultMeetingApps,
            nativePlayers: Set<String> = Preferences.defaultNativePlayers,
            browsers: Set<String> = Preferences.defaultBrowsers,
            expectedState: SessionState,
            expectInspectorCalled: Bool = false
        ) {
            var inspectorCalled = false
            let classification = SessionDetector.classify(
                processes: processes,
                ignoredApps: ignoredApps,
                meetingApps: meetingApps,
                nativePlayers: nativePlayers,
                browsers: browsers,
                tabInspector: { bundleID in
                    inspectorCalled = true
                    return TabInspection(
                        bundleID: bundleID,
                        activeTabURL: "https://www.youtube.com/watch?v=123",
                        allTabURLs: [],
                        verdict: .video("https://www.youtube.com/watch?v=123"),
                        reason: "test video",
                        scriptError: nil
                    )
                }
            )

            let statePassed = classification.state == expectedState
            let inspectorPassed = inspectorCalled == expectInspectorCalled
            let passed = statePassed && inspectorPassed
            if !passed { failures += 1 }
            print("\(passed ? "✓" : "✗ FAIL")  \(name)")
            if !statePassed {
                print("      expected state \(expectedState), got \(classification.state) (\(classification.reason))")
            }
            if !inspectorPassed {
                print("      expected tabInspector called: \(expectInspectorCalled), actual: \(inspectorCalled)")
            }
        }

        // Stage 1 (Mic): Ignored app with live mic is NOT a meeting
        check(
            name: "ignored app holding mic is idle",
            processes: [AudioProcess(bundleID: "com.spotify.client", isRunningInput: true)],
            ignoredApps: ["com.spotify.client"],
            meetingApps: ["com.spotify.client", "us.zoom.xos"],
            expectedState: .idle
        )

        // Stage 1 (Mic): Ignored app helper holding mic is NOT a meeting
        check(
            name: "ignored app helper holding mic is idle",
            processes: [AudioProcess(bundleID: "com.spotify.client.helper", isRunningInput: true)],
            ignoredApps: ["com.spotify.client"],
            meetingApps: ["com.spotify.client", "us.zoom.xos"],
            expectedState: .idle
        )

        // Stage 2 (Player): Ignored native player holding output is NOT video
        check(
            name: "ignored native player holding output is idle",
            processes: [AudioProcess(bundleID: "org.videolan.vlc", isRunningOutput: true)],
            ignoredApps: ["org.videolan.vlc"],
            nativePlayers: ["org.videolan.vlc"],
            expectedState: .idle
        )

        // Stage 2 (Player): Ignored native player helper holding output is NOT video
        check(
            name: "ignored native player helper holding output is idle",
            processes: [AudioProcess(bundleID: "org.videolan.vlc.helper", isRunningOutput: true)],
            ignoredApps: ["org.videolan.vlc"],
            nativePlayers: ["org.videolan.vlc"],
            expectedState: .idle
        )

        // Stage 3 (Browser): Ignored browser holding output does NOT trigger AppleScript or video
        check(
            name: "ignored browser holding output is idle and tab inspection never runs",
            processes: [AudioProcess(bundleID: "com.google.Chrome", isRunningOutput: true)],
            ignoredApps: ["com.google.Chrome"],
            browsers: ["com.google.Chrome"],
            expectedState: .idle,
            expectInspectorCalled: false
        )

        // Stage 3 (Browser): Ignored browser helper holding output does NOT trigger AppleScript
        check(
            name: "ignored browser helper holding output is idle and tab inspection never runs",
            processes: [AudioProcess(bundleID: "com.google.Chrome.helper", isRunningOutput: true)],
            ignoredApps: ["com.google.Chrome"],
            browsers: ["com.google.Chrome"],
            expectedState: .idle,
            expectInspectorCalled: false
        )

        // Stage 3 (Safari GPU helper): Safari in ignoredApps suppresses com.apple.WebKit.GPU
        check(
            name: "Safari in ignoredApps suppresses WebKit GPU process",
            processes: [AudioProcess(bundleID: "com.apple.WebKit.GPU", isRunningOutput: true)],
            ignoredApps: ["com.apple.Safari"],
            browsers: ["com.apple.Safari"],
            expectedState: .idle,
            expectInspectorCalled: false
        )

        // Contrast: Non-ignored browser holding output DOES trigger inspection
        check(
            name: "non-ignored browser holding output triggers inspection",
            processes: [AudioProcess(bundleID: "com.google.Chrome.helper", isRunningOutput: true)],
            ignoredApps: ["com.spotify.client"],
            browsers: ["com.google.Chrome"],
            expectedState: .video,
            expectInspectorCalled: true
        )

        return failures
    }

    // MARK: - Unsupported Browser Security Regression Cases

    private static func runUnsupportedBrowserCases() -> Int {
        var failures = 0
        let suiteName = "com.mike.movebreak.tests.browser.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            print("✗ FAIL  could not instantiate isolated UserDefaults suite")
            return 1
        }
        defer {
            testDefaults.removePersistentDomain(forName: suiteName)
        }

        func check<T: Equatable>(_ name: String, expected: T, actual: T) {
            let passed = expected == actual
            if !passed { failures += 1 }
            print("\(passed ? "✓" : "✗ FAIL")  \(name)")
            if !passed {
                print("      expected \(expected), got \(actual)")
            }
        }

        Preferences.withDefaults(testDefaults) {
            // Attempting to configure an unsupported browser is rejected
            testDefaults.set(["com.unsupported.browser", "com.malicious.app"], forKey: "browsers")
            check(
                "unsupported browsers rejected; falls back to default supported browsers",
                expected: Preferences.defaultBrowsers,
                actual: Preferences.browsers
            )

            // Configuring a mix of supported and unsupported keeps only supported
            testDefaults.set(["com.google.Chrome", "com.malicious.app"], forKey: "browsers")
            check(
                "mix of supported and unsupported keeps only supported",
                expected: Set(["com.google.Chrome"]),
                actual: Preferences.browsers
            )
        }

        // BrowserTabInspector support verification
        check(
            "Chrome is supported",
            expected: true,
            actual: BrowserTabInspector.isBrowserSupported(bundleID: "com.google.Chrome")
        )
        check(
            "Safari is supported",
            expected: true,
            actual: BrowserTabInspector.isBrowserSupported(bundleID: "com.apple.Safari")
        )
        check(
            "Arbitrary app is NOT supported",
            expected: false,
            actual: BrowserTabInspector.isBrowserSupported(bundleID: "com.malicious.app")
        )
        check(
            "Firefox is NOT supported (no AppleScript tab dictionary)",
            expected: false,
            actual: BrowserTabInspector.isBrowserSupported(bundleID: "org.mozilla.firefox")
        )

        // Inspecting an unsupported browser returns unknown and never runs AppleScript
        let inspector = BrowserTabInspector()
        let inspection = inspector.inspectFresh(bundleID: "com.malicious.app")
        check(
            "inspecting unsupported browser returns unknown verdict",
            expected: TabVerdict.unknown,
            actual: inspection.verdict
        )
        check(
            "inspecting unsupported browser gives unsupported reason",
            expected: "no AppleScript tab support for this browser",
            actual: inspection.reason
        )
        check(
            "inspecting unsupported browser has no scriptError",
            expected: nil,
            actual: inspection.scriptError
        )

        // SessionDetector with an unsupported browser process remains idle
        var inspectorInvoked = false
        let classification = SessionDetector.classify(
            processes: [AudioProcess(bundleID: "com.malicious.app", isRunningOutput: true)],
            ignoredApps: [],
            meetingApps: [],
            nativePlayers: [],
            browsers: ["com.malicious.app"],
            tabInspector: { bundleID in
                inspectorInvoked = true
                return inspector.inspectFresh(bundleID: bundleID)
            }
        )
        check(
            "unsupported browser stream results in idle state",
            expected: SessionState.idle,
            actual: classification.state
        )
        check(
            "inspector was called safely without error",
            expected: true,
            actual: inspectorInvoked
        )

        return failures
    }

    // MARK: - Video vs Music Tab Classification Cases

    private static func runClassificationCases() -> Int {
        let cases: [Case] = [
            // The original distinction: a paused tab never reaches this code at all
            // (no output stream), so anything here is already "something is playing".
            Case(name: "YouTube video in the active tab",
                 activeURL: "https://www.youtube.com/watch?v=abc123",
                 allURLs: [], expectVideo: true),

            Case(name: "YouTube Shorts in the active tab",
                 activeURL: "https://www.youtube.com/shorts/xyz",
                 allURLs: [], expectVideo: true),

            // Music must never fire.
            Case(name: "Relisten in the active tab",
                 activeURL: "https://relisten.net/phish/1997/11/17",
                 allURLs: [], expectVideo: false),

            Case(name: "SiriusXM in the active tab",
                 activeURL: "https://player.siriusxm.com/home",
                 allURLs: [], expectVideo: false),

            Case(name: "YouTube Music is music, not video",
                 activeURL: "https://music.youtube.com/watch?v=abc123",
                 allURLs: [], expectVideo: false),

            Case(name: "archive.org details page (Relisten's source)",
                 activeURL: "https://archive.org/details/ph1997-11-17",
                 allURLs: [], expectVideo: false),

            // The ambiguity case that motivated this whole design.
            Case(name: "Relisten playing, working in a docs tab → no prompt",
                 activeURL: "https://docs.google.com/document/d/1",
                 allURLs: ["https://relisten.net/phish/1997/11/17",
                           "https://docs.google.com/document/d/1"],
                 expectVideo: false),

            Case(name: "Relisten + YouTube both open, YouTube active → video",
                 activeURL: "https://www.youtube.com/watch?v=abc123",
                 allURLs: ["https://relisten.net/phish/1997/11/17",
                           "https://www.youtube.com/watch?v=abc123"],
                 expectVideo: true),

            Case(name: "Relisten + YouTube both open, Relisten active → no prompt",
                 activeURL: "https://relisten.net/phish/1997/11/17",
                 allURLs: ["https://relisten.net/phish/1997/11/17",
                           "https://www.youtube.com/watch?v=abc123"],
                 expectVideo: false),

            Case(name: "Relisten + YouTube open, neither active → ambiguous, no prompt",
                 activeURL: "https://mail.google.com/",
                 allURLs: ["https://relisten.net/phish/1997/11/17",
                           "https://www.youtube.com/watch?v=abc123",
                           "https://mail.google.com/"],
                 expectVideo: false),

            // Fallback scan: video in a background window, nothing musical open.
            Case(name: "Video in a background window, no music → video",
                 activeURL: "https://mail.google.com/",
                 allURLs: ["https://www.youtube.com/watch?v=abc123",
                           "https://mail.google.com/"],
                 expectVideo: true),

            Case(name: "Two video tabs, neither active → ambiguous, no prompt",
                 activeURL: "https://mail.google.com/",
                 allURLs: ["https://www.youtube.com/watch?v=a",
                           "https://vimeo.com/12345",
                           "https://mail.google.com/"],
                 expectVideo: false),

            // Host matching details.
            Case(name: "www. prefix still matches a bare-domain pattern",
                 activeURL: "https://www.vimeo.com/12345",
                 allURLs: [], expectVideo: true),

            Case(name: "YouTube home page is not a video",
                 activeURL: "https://www.youtube.com/",
                 allURLs: [], expectVideo: false),

            Case(name: "Unrelated site → no prompt",
                 activeURL: "https://news.ycombinator.com/",
                 allURLs: ["https://news.ycombinator.com/"], expectVideo: false),

            Case(name: "No tabs at all → no prompt",
                 activeURL: nil, allURLs: [], expectVideo: false),

            // Browser calls. Chrome releases the mic stream when a Meet call is muted, so
            // the stage-1 mic signal disappears and only the URL identifies the call.
            Case(name: "Google Meet in the active tab → meeting",
                 activeURL: "https://meet.google.com/abc-defg-hij",
                 allURLs: [], expectMeeting: true),

            Case(name: "Meet in a background window → meeting",
                 activeURL: "https://mail.google.com/",
                 allURLs: ["https://meet.google.com/abc-defg-hij",
                           "https://mail.google.com/"],
                 expectMeeting: true),

            Case(name: "Meet call outranks a music tab (muted Meet + phish.in)",
                 activeURL: "https://mail.google.com/",
                 allURLs: ["https://relisten.net/phish/1997/11/17",
                           "https://meet.google.com/abc-defg-hij",
                           "https://mail.google.com/"],
                 expectMeeting: true),

            Case(name: "Teams web call → meeting",
                 activeURL: "https://teams.microsoft.com/v2/#/conversations/x",
                 allURLs: [], expectMeeting: true),

            Case(name: "Zoom web client → meeting",
                 activeURL: "https://us02web.zoom.us/wc/join/123456",
                 allURLs: [], expectMeeting: true),

            Case(name: "Gmail alone is not a meeting",
                 activeURL: "https://mail.google.com/",
                 allURLs: ["https://mail.google.com/"]),
        ]

        var failures = 0
        for testCase in cases {
            let (verdict, reason) = BrowserTabInspector.classify(
                activeURL: testCase.activeURL, allURLs: testCase.allURLs
            )
            let passed = verdict.isVideo == testCase.expectVideo
                && verdict.isMeeting == testCase.expectMeeting
            if !passed { failures += 1 }

            func label(video: Bool, meeting: Bool) -> String {
                if meeting { return "MEETING" }
                if video { return "VIDEO" }
                return "no prompt"
            }

            let mark = passed ? "✓" : "✗ FAIL"
            print("\(mark)  \(testCase.name)")
            print("      expected \(label(video: testCase.expectVideo, meeting: testCase.expectMeeting))"
                  + ", got \(label(video: verdict.isVideo, meeting: verdict.isMeeting)) — \(reason)")
        }
        return failures
    }

    static func run() -> Never {
        var failures = 0
        print("MoveBreak — self-test")
        print(String(repeating: "─", count: 78))
        print("Bundle identity (helper process → owning app)")
        failures += runIdentityCases()
        print("")
        print("Exercise catalog + default routines")
        failures += runCatalogCases()
        print("")
        print("Runtime configuration: numeric bounds and safety")
        failures += runNumericPreferencesCases()
        print("")
        print("Runtime configuration: list normalization and limits")
        failures += runListNormalizationCases()
        print("")
        print("URL pattern matching and host boundary enforcement")
        failures += runHostBoundaryCases()
        print("")
        print("Ignored apps precedence across all detection stages")
        failures += runIgnoredAppsPrecedenceCases()
        print("")
        print("Unsupported browser security and AppleScript allowlist")
        failures += runUnsupportedBrowserCases()
        print("")
        print("Video vs music classification")
        failures += runClassificationCases()

        print(String(repeating: "─", count: 78))
        if failures == 0 {
            print("All cases passed.")
            exit(0)
        } else {
            print("\(failures) case(s) FAILED.")
            exit(1)
        }
    }
}
