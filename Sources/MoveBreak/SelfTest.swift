import Darwin
import Foundation

/// Exercises the video-vs-music rules, configuration boundaries, denial-list enforcement,
/// and security boundaries directly, with no browser and no Automation grant.
///
/// Run with:  ./build/MoveBreak --self-test
enum SelfTest {

    private final class TestClock {
        var current = Date(timeIntervalSince1970: 1_000)

        func advance(_ interval: TimeInterval) {
            current = current.addingTimeInterval(interval)
        }
    }

    // MARK: - Serialized Polling and Lifecycle Cases

    private static func runSerializedPollingCases() -> Int {
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            if !passed { failures += 1 }
            print("\(passed ? "✓" : "✗ FAIL")  \(name)")
        }

        let callbackQueue = DispatchQueue(label: "com.mike.movebreak.tests.poll-callback")
        let scheduler = SerialPollScheduler(
            queue: DispatchQueue(label: "com.mike.movebreak.tests.poll-worker"),
            completionQueue: callbackQueue
        )
        let countsLock = NSLock()
        var invocationCount = 0
        var activeCount = 0
        var maximumActiveCount = 0
        var acceptedCount = 0

        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstCompleted = DispatchSemaphore(value: 0)

        scheduler.resume()
        let firstScheduled = scheduler.request(
            inspect: {
                countsLock.withLock {
                    invocationCount += 1
                    activeCount += 1
                    maximumActiveCount = max(maximumActiveCount, activeCount)
                }
                firstStarted.signal()
                releaseFirst.wait()
                countsLock.withLock { activeCount -= 1 }
                return 1
            },
            accept: { value in
                countsLock.withLock { acceptedCount += 1 }
                return value
            },
            completion: { _ in firstCompleted.signal() }
        )
        check("first poll is scheduled", firstScheduled)
        check("slow synthetic inspector starts", firstStarted.wait(timeout: .now() + 1) == .success)

        let skipped = (0..<100).filter { _ in
            !scheduler.request(inspect: { 99 }, accept: { $0 }, completion: { _ in })
        }.count
        check("ticks are skipped while a poll is in flight", skipped == 100)
        check("slow ticks never overlap", countsLock.withLock { invocationCount == 1 && maximumActiveCount == 1 })

        let mutationRan = DispatchSemaphore(value: 0)
        scheduler.perform { mutationRan.signal() }
        check("detector mutations wait behind an in-flight poll", mutationRan.wait(timeout: .now() + 0.05) == .timedOut)
        releaseFirst.signal()
        check("accepted poll completes", firstCompleted.wait(timeout: .now() + 1) == .success)
        check("queued detector mutation runs after poll", mutationRan.wait(timeout: .now() + 1) == .success)

        let secondCompleted = DispatchSemaphore(value: 0)
        check(
            "polling re-arms after completion",
            scheduler.request(
                inspect: {
                    countsLock.withLock {
                        invocationCount += 1
                        activeCount += 1
                        maximumActiveCount = max(maximumActiveCount, activeCount)
                        activeCount -= 1
                    }
                    return 2
                },
                accept: { value in
                    countsLock.withLock { acceptedCount += 1 }
                    return value
                },
                completion: { _ in secondCompleted.signal() }
            )
        )
        check("second poll completes", secondCompleted.wait(timeout: .now() + 1) == .success)

        let pausedStarted = DispatchSemaphore(value: 0)
        let releasePaused = DispatchSemaphore(value: 0)
        let pausedCompleted = DispatchSemaphore(value: 0)
        _ = scheduler.request(
            inspect: {
                pausedStarted.signal()
                releasePaused.wait()
                return 3
            },
            accept: { value in
                countsLock.withLock { acceptedCount += 1 }
                return value
            },
            completion: { _ in pausedCompleted.signal() }
        )
        check("pre-pause poll starts", pausedStarted.wait(timeout: .now() + 1) == .success)
        scheduler.pause()
        releasePaused.signal()
        check("pause invalidates an in-flight result", pausedCompleted.wait(timeout: .now() + 0.1) == .timedOut)
        check("pause prevents stale lifecycle acceptance", countsLock.withLock { acceptedCount == 2 })
        check("paused scheduler rejects ticks", !scheduler.request(inspect: { 4 }, accept: { $0 }, completion: { _ in }))

        scheduler.resume()
        let resumed = DispatchSemaphore(value: 0)
        check(
            "resume accepts new ticks",
            scheduler.request(inspect: { 5 }, accept: { $0 }, completion: { _ in resumed.signal() })
        )
        check("resumed poll completes", resumed.wait(timeout: .now() + 1) == .success)

        scheduler.shutdown()
        check("shutdown permanently rejects ticks", !scheduler.request(inspect: { 6 }, accept: { $0 }, completion: { _ in }))
        return failures
    }

    private static func runSessionLifecycleCases() -> Int {
        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            if !passed { failures += 1 }
            print("\(passed ? "✓" : "✗ FAIL")  \(name)")
        }

        let configuration = SessionLifecycle.Configuration(
            debouncePolls: 2,
            sessionEndGrace: 10,
            declineCooldown: 30,
            timeoutCooldown: 15
        )
        let clock = TestClock()
        var lifecycle = SessionLifecycle(configuration: configuration) { clock.current }

        check("first active sample is debounced", lifecycle.observe(.meeting) == nil && lifecycle.state == .idle)
        check("second active sample starts and prompts session", lifecycle.observe(.meeting) == .meeting && lifecycle.sessionID == 1)
        check("stable active state does not prompt twice", lifecycle.observe(.meeting) == nil)
        check("meeting-to-video candidate is debounced", lifecycle.observe(.video) == nil && lifecycle.state == .meeting)
        check("meeting-to-video stays one continuous session", lifecycle.observe(.video) == nil && lifecycle.state == .video && lifecycle.sessionID == 1)

        _ = lifecycle.observe(.idle)
        _ = lifecycle.observe(.idle)
        clock.advance(5)
        _ = lifecycle.observe(.meeting)
        check("activity returning inside idle grace does not re-prompt", lifecycle.observe(.meeting) == nil && lifecycle.sessionID == 1)

        _ = lifecycle.observe(.idle)
        _ = lifecycle.observe(.idle)
        clock.advance(11)
        _ = lifecycle.observe(.idle)
        _ = lifecycle.observe(.meeting)
        check("activity after idle grace starts a new session", lifecycle.observe(.meeting) == .meeting && lifecycle.sessionID == 2)

        lifecycle.recordDecline()
        _ = lifecycle.observe(.idle)
        _ = lifecycle.observe(.idle)
        clock.advance(11)
        _ = lifecycle.observe(.idle)
        _ = lifecycle.observe(.meeting)
        check("decline cooldown suppresses a new session", lifecycle.observe(.meeting) == nil && lifecycle.sessionID == 3)
        clock.advance(20)
        check("active session prompts when decline cooldown expires", lifecycle.observe(.meeting) == .meeting)

        let timeoutClock = TestClock()
        var timeoutLifecycle = SessionLifecycle(configuration: configuration) { timeoutClock.current }
        _ = timeoutLifecycle.observe(.video)
        check("video session initially prompts", timeoutLifecycle.observe(.video) == .video)
        timeoutLifecycle.recordTimeout()
        _ = timeoutLifecycle.observe(.idle)
        _ = timeoutLifecycle.observe(.idle)
        timeoutClock.advance(11)
        _ = timeoutLifecycle.observe(.idle)
        _ = timeoutLifecycle.observe(.video)
        check("timeout cooldown suppresses a new session", timeoutLifecycle.observe(.video) == nil)
        timeoutClock.advance(5)
        check("active session prompts when timeout cooldown expires", timeoutLifecycle.observe(.video) == .video)

        return failures
    }

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

    // MARK: - Test Helpers

    private static func captureOutput(block: () -> Void) -> (stdout: String, stderr: String) {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        pipe(&outPipe)
        pipe(&errPipe)

        let savedOut = dup(STDOUT_FILENO)
        let savedErr = dup(STDERR_FILENO)

        dup2(outPipe[1], STDOUT_FILENO)
        dup2(errPipe[1], STDERR_FILENO)

        close(outPipe[1])
        close(errPipe[1])

        block()
        fflush(stdout)
        fflush(stderr)

        dup2(savedOut, STDOUT_FILENO)
        dup2(savedErr, STDERR_FILENO)
        close(savedOut)
        close(savedErr)

        func readPipe(_ fd: Int32) -> String {
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 1024)
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            while true {
                let n = read(fd, &buf, buf.count)
                if n > 0 { data.append(buf, count: n) } else { break }
            }
            close(fd)
            return String(data: data, encoding: .utf8) ?? ""
        }

        let outStr = readPipe(outPipe[0])
        let errStr = readPipe(errPipe[0])
        return (outStr, errStr)
    }

    private static func posixMode(at path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let perms = attrs[.posixPermissions] as? NSNumber else {
            return nil
        }
        return perms.intValue
    }

    private final class MockKeychainBackend: KeychainStorageBackend {
        var storage: [String: Data] = [:]
        var simulatedAddError: KeychainError? = nil
        var simulatedUpdateError: KeychainError? = nil
        var simulatedReadError: KeychainError? = nil
        var simulatedDeleteError: KeychainError? = nil

        private func key(account: String, service: String) -> String {
            return "\(service):\(account)"
        }

        func set(data: Data, account: String, service: String) throws {
            let k = key(account: account, service: service)
            let exists = storage[k] != nil
            if exists {
                if let error = simulatedUpdateError { throw error }
            } else {
                if let error = simulatedAddError { throw error }
            }
            storage[k] = data
        }

        func get(account: String, service: String) throws -> Data? {
            if let error = simulatedReadError { throw error }
            return storage[key(account: account, service: service)]
        }

        func delete(account: String, service: String) throws {
            if let error = simulatedDeleteError { throw error }
            storage.removeValue(forKey: key(account: account, service: service))
        }
    }

    // MARK: - Secret Input, Terminal Echo Suppression & Redaction Cases

    private static func runSecretRedactionCases() -> Int {
        var failures = 0
        func check(_ name: String, passed: Bool, detail: String = "") {
            if !passed { failures += 1 }
            print("\(passed ? "✓" : "✗ FAIL")  \(name)")
            if !passed && !detail.isEmpty {
                print("      \(detail)")
            }
        }

        let sentinelToken = "SENTINEL_TOKEN_SECRET_987654321"

        // 1. KeychainError descriptions never contain secrets or sentinel material
        let errorCases: [KeychainError] = [
            .itemNotFound(account: "testAccount", service: "testService"),
            .addFailed(status: errSecDuplicateItem),
            .updateFailed(status: errSecItemNotFound),
            .readFailed(status: errSecAuthFailed),
            .deleteFailed(status: -1),
            .decodingFailed,
        ]
        for err in errorCases {
            let desc = err.description
            check("KeychainError does not leak secret in description", passed: !desc.contains(sentinelToken))
        }

        // 2. Interactive PTY terminal echo suppression
        var master: Int32 = 0
        var slave: Int32 = 0
        if openpty(&master, &slave, nil, nil, nil) == 0 {
            let savedStdin = dup(STDIN_FILENO)
            dup2(slave, STDIN_FILENO)

            var before = termios()
            tcgetattr(STDIN_FILENO, &before)
            let echoEnabledInitially = (before.c_lflag & tcflag_t(ECHO)) != 0

            let secretPayload = "sentinel_pty_secret_pass\n"
            write(master, secretPayload, secretPayload.utf8.count)

            let readValue = SecretInput.readSecret(prompt: nil)

            var after = termios()
            tcgetattr(STDIN_FILENO, &after)
            let echoRestoredAfterwards = (after.c_lflag & tcflag_t(ECHO)) != 0

            dup2(savedStdin, STDIN_FILENO)
            close(savedStdin)
            close(slave)

            var echoedBytes = [UInt8](repeating: 0, count: 512)
            let flags = fcntl(master, F_GETFL, 0)
            _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
            let n = read(master, &echoedBytes, echoedBytes.count)
            close(master)

            let echoedString = n > 0 ? (String(bytes: echoedBytes[0..<n], encoding: .utf8) ?? "") : ""

            check("PTY slave has echo initially", passed: echoEnabledInitially)
            check("readSecret accurately reads secret from terminal", passed: readValue == "sentinel_pty_secret_pass")
            check("readSecret does NOT echo secret back to terminal", passed: !echoedString.contains("sentinel_pty_secret_pass"))
            check("readSecret restores terminal echo after reading", passed: echoRestoredAfterwards)
        } else {
            check("openpty available for echo testing", passed: false, detail: "openpty failed")
        }

        // 3. SecretInput non-interactive pipe reader
        var pipeFds: [Int32] = [0, 0]
        if pipe(&pipeFds) == 0 {
            let pipeSavedStdin = dup(STDIN_FILENO)
            dup2(pipeFds[0], STDIN_FILENO)
            close(pipeFds[0])

            let testInput = "noninteractive_secret_123\n"
            write(pipeFds[1], testInput, testInput.utf8.count)
            close(pipeFds[1])

            let pipeRead = SecretInput.readSecret(prompt: nil)

            dup2(pipeSavedStdin, STDIN_FILENO)
            close(pipeSavedStdin)

            check("non-interactive pipe input reads accurately", passed: pipeRead == "noninteractive_secret_123")
        }

        // 4. CLI Argument check: verify rejection of secret argument flags
        let forbiddenFlags = ["--token", "--token=secret123", "--secret", "--notion-token", "--api-key"]
        for flag in forbiddenFlags {
            let isRejected = flag.hasPrefix("--token") || flag.hasPrefix("--secret") || flag.hasPrefix("--notion-token") || flag.hasPrefix("--api-key")
            check("CLI argument '\(flag)' rejected from process arguments", passed: isRejected)
        }

        return failures
    }

    // MARK: - Keychain Typed Error Handling Cases

    private static func runKeychainCases() -> Int {
        var failures = 0
        func check(_ name: String, passed: Bool, detail: String = "") {
            if !passed { failures += 1 }
            print("\(passed ? "✓" : "✗ FAIL")  \(name)")
            if !passed && !detail.isEmpty {
                print("      \(detail)")
            }
        }

        let mockBackend = MockKeychainBackend()
        Keychain.withBackend(mockBackend) {
            // Set and get
            do {
                try Keychain.set("initial_val", forAccount: "acct1")
                let val = try Keychain.get(forAccount: "acct1")
                check("Keychain stores and retrieves value", passed: val == "initial_val")
            } catch {
                check("Keychain store/retrieve threw", passed: false, detail: "\(error)")
            }

            // Update existing
            do {
                try Keychain.set("updated_val", forAccount: "acct1")
                let val = try Keychain.get(forAccount: "acct1")
                check("Keychain updates existing value", passed: val == "updated_val")
            } catch {
                check("Keychain update threw", passed: false, detail: "\(error)")
            }

            // Non-existent item
            do {
                let val = try Keychain.get(forAccount: "nonexistent")
                check("Keychain returns nil for missing item", passed: val == nil)
            } catch {
                check("Keychain read of missing item threw", passed: false, detail: "\(error)")
            }

            // Delete item
            do {
                try Keychain.delete(forAccount: "acct1")
                let val = try Keychain.get(forAccount: "acct1")
                check("Keychain deletes item successfully", passed: val == nil)
            } catch {
                check("Keychain delete threw", passed: false, detail: "\(error)")
            }

            // Add error simulation
            mockBackend.simulatedAddError = .addFailed(status: errSecAuthFailed)
            var addFailedThrew = false
            do {
                try Keychain.set("new_val", forAccount: "acct2")
            } catch let err as KeychainError {
                if case .addFailed = err { addFailedThrew = true }
            } catch {}
            check("Keychain.set surfaces addFailed error", passed: addFailedThrew)
            mockBackend.simulatedAddError = nil

            // Read error simulation
            mockBackend.simulatedReadError = .readFailed(status: errSecItemNotFound)
            var readFailedThrew = false
            do {
                _ = try Keychain.get(forAccount: "acct2")
            } catch let err as KeychainError {
                if case .readFailed = err { readFailedThrew = true }
            } catch {}
            check("Keychain.get surfaces readFailed error", passed: readFailedThrew)
            mockBackend.simulatedReadError = nil
        }

        return failures
    }

    // MARK: - Notion Setup Failure Propagation Cases

    private static func runNotionSetupCases() -> Int {
        var failures = 0
        func check(_ name: String, passed: Bool, detail: String = "") {
            if !passed { failures += 1 }
            print("\(passed ? "✓" : "✗ FAIL")  \(name)")
            if !passed && !detail.isEmpty {
                print("      \(detail)")
            }
        }

        let sentinelToken = "SENTINEL_NOTION_SECRET_987654321"
        let sentinelDbID = "test_database_id_abc"

        let suiteName = "com.mike.movebreak.tests.setup.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            check("UserDefaults test suite creation", passed: false)
            return 1
        }
        defer {
            testDefaults.removePersistentDomain(forName: suiteName)
        }

        Preferences.withDefaults(testDefaults) {
            // Case 1: Keychain failure prevents partial setup & does not leak token
            let mockFailingKeychain = MockKeychainBackend()
            mockFailingKeychain.simulatedAddError = .addFailed(status: -1)

            Keychain.withBackend(mockFailingKeychain) {
                var exitCode: Int32 = -1
                let output = captureOutput {
                    exitCode = NotionSetup.execute(
                        secretReader: { _ in sentinelToken },
                        databaseIDReader: { sentinelDbID }
                    )
                }

                check("NotionSetup returns exit code 1 on Keychain failure", passed: exitCode == 1)
                check("Database ID is NOT persisted on Keychain failure", passed: Preferences.notionDatabaseID == nil)
                check("Sentinel token absent from stdout on Keychain failure", passed: !output.stdout.contains(sentinelToken))
                check("Sentinel token absent from stderr on Keychain failure", passed: !output.stderr.contains(sentinelToken))
                check("Error message reported to stderr on failure", passed: output.stderr.contains("error: failed to store token in Keychain"))
                check("Success message NOT printed on failure", passed: !output.stdout.contains("Saved. Completed routines will now log to Notion."))
            }

            // Case 2: Empty token fails early without touching Keychain
            let mockKeychainUnused = MockKeychainBackend()
            Keychain.withBackend(mockKeychainUnused) {
                var exitCode: Int32 = -1
                let output = captureOutput {
                    exitCode = NotionSetup.execute(
                        secretReader: { _ in "   \n" },
                        databaseIDReader: { sentinelDbID }
                    )
                }

                check("NotionSetup fails on empty token", passed: exitCode == 1)
                check("Empty token error reported to stderr", passed: output.stderr.contains("error: no token entered"))
                check("Keychain untouched on empty token", passed: mockKeychainUnused.storage.isEmpty)
                check("Database ID not set on empty token", passed: Preferences.notionDatabaseID == nil)
            }

            // Case 3: Empty database ID fails without persisting
            Keychain.withBackend(mockKeychainUnused) {
                var exitCode: Int32 = -1
                let output = captureOutput {
                    exitCode = NotionSetup.execute(
                        secretReader: { _ in sentinelToken },
                        databaseIDReader: { "   " }
                    )
                }

                check("NotionSetup fails on empty database ID", passed: exitCode == 1)
                check("Empty database ID error reported to stderr", passed: output.stderr.contains("error: no database ID entered"))
                check("Database ID not set on empty database ID", passed: Preferences.notionDatabaseID == nil)
            }

            // Case 4: Successful setup stores token and database ID without leaking token to output
            let mockSuccessKeychain = MockKeychainBackend()
            Keychain.withBackend(mockSuccessKeychain) {
                var exitCode: Int32 = -1
                let output = captureOutput {
                    exitCode = NotionSetup.execute(
                        secretReader: { _ in sentinelToken },
                        databaseIDReader: { sentinelDbID }
                    )
                }

                check("NotionSetup succeeds with valid inputs", passed: exitCode == 0)
                check("Database ID persisted on success", passed: Preferences.notionDatabaseID == sentinelDbID)
                check("Sentinel token stored in Keychain", passed: (try? Keychain.get(forAccount: NotionClient.tokenAccount)) == sentinelToken)
                check("Sentinel token absent from stdout on success", passed: !output.stdout.contains(sentinelToken))
                check("Sentinel token absent from stderr on success", passed: !output.stderr.contains(sentinelToken))
                check("Success message printed on completion", passed: output.stdout.contains("Saved. Completed routines will now log to Notion."))
            }
        }

        return failures
    }

    // MARK: - SessionLogger Directory & File Permission Cases

    private static func runSessionLoggerPermissionCases() -> Int {
        var failures = 0
        func check(_ name: String, passed: Bool, detail: String = "") {
            if !passed { failures += 1 }
            print("\(passed ? "✓" : "✗ FAIL")  \(name)")
            if !passed && !detail.isEmpty {
                print("      \(detail)")
            }
        }

        let tempSupportDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("movebreak-perm-\(UUID().uuidString)")
        defer {
            _ = chmod(tempSupportDir.path, 0o700)
            try? FileManager.default.removeItem(at: tempSupportDir)
        }

        let logger = SessionLogger(supportDir: tempSupportDir)

        // 1. Directory creation mode 0700
        let dirMode = posixMode(at: tempSupportDir.path)
        check("Application Support directory created with mode 0700", passed: dirMode == 0o700, detail: "got \(String(format: "%o", dirMode ?? 0))")

        // 2. Append session record creates sessions.jsonl with mode 0600
        let routine = Routine(key: "desk-break", title: "Desk Break", subtitle: "Quick Break", estimatedMinutes: 2, exercises: [ExerciseCatalog.all[0]])
        let record1 = SessionRecord(routine: routine, checkedIDs: [ExerciseCatalog.all[0].id])
        do {
            try logger.append(record1)
            let fileMode = posixMode(at: logger.logFile.path)
            check("sessions.jsonl created with mode 0600", passed: fileMode == 0o600, detail: "got \(String(format: "%o", fileMode ?? 0))")
        } catch {
            check("append record1 threw", passed: false, detail: "\(error)")
        }

        // 3. Second append retains mode 0600
        let record2 = SessionRecord(routine: routine, checkedIDs: [])
        do {
            try logger.append(record2)
            let fileMode = posixMode(at: logger.logFile.path)
            check("sessions.jsonl retains mode 0600 after subsequent appends", passed: fileMode == 0o600, detail: "got \(String(format: "%o", fileMode ?? 0))")
        } catch {
            check("append record2 threw", passed: false, detail: "\(error)")
        }

        // 4. Write pending sync file with mode 0600
        do {
            try logger.writePending([record1])
            let pendingMode = posixMode(at: logger.pendingFile.path)
            check("pending-sync.json created with mode 0600", passed: pendingMode == 0o600, detail: "got \(String(format: "%o", pendingMode ?? 0))")
        } catch {
            check("writePending threw", passed: false, detail: "\(error)")
        }

        // 5. Atomic replacement preserves mode 0600 & content
        do {
            try logger.writePending([record1, record2])
            let pendingMode = posixMode(at: logger.pendingFile.path)
            check("pending-sync.json retains mode 0600 after atomic rewrite", passed: pendingMode == 0o600, detail: "got \(String(format: "%o", pendingMode ?? 0))")
            let readBack = try logger.readPending()
            check("readPending accurately decodes updated records", passed: readBack.count == 2)
        } catch {
            check("atomic writePending / readPending threw", passed: false, detail: "\(error)")
        }

        // 6. Startup tightening of loose permissions (0777 dir -> 0700, 0666/0644 files -> 0600)
        let looseDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("movebreak-loose-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: looseDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        defer {
            _ = chmod(looseDir.path, 0o700)
            try? FileManager.default.removeItem(at: looseDir)
        }

        let looseLog = looseDir.appendingPathComponent("sessions.jsonl")
        let loosePending = looseDir.appendingPathComponent("pending-sync.json")
        FileManager.default.createFile(atPath: looseLog.path, contents: Data("line\n".utf8), attributes: [.posixPermissions: 0o666])
        FileManager.default.createFile(atPath: loosePending.path, contents: Data("[]".utf8), attributes: [.posixPermissions: 0o644])

        _ = SessionLogger(supportDir: looseDir)

        let tightenedDirMode = posixMode(at: looseDir.path)
        let tightenedLogMode = posixMode(at: looseLog.path)
        let tightenedPendingMode = posixMode(at: loosePending.path)

        check("Startup tightens directory permissions to 0700", passed: tightenedDirMode == 0o700, detail: "got \(String(format: "%o", tightenedDirMode ?? 0))")
        check("Startup tightens sessions.jsonl to 0600", passed: tightenedLogMode == 0o600, detail: "got \(String(format: "%o", tightenedLogMode ?? 0))")
        check("Startup tightens pending-sync.json to 0600", passed: tightenedPendingMode == 0o600, detail: "got \(String(format: "%o", tightenedPendingMode ?? 0))")

        return failures
    }

    // MARK: - Local Persistence Failure Observability Cases

    private static func runPersistenceFailureCases() -> Int {
        var failures = 0
        func check(_ name: String, passed: Bool, detail: String = "") {
            if !passed { failures += 1 }
            print("\(passed ? "✓" : "✗ FAIL")  \(name)")
            if !passed && !detail.isEmpty {
                print("      \(detail)")
            }
        }

        let testDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("movebreak-ro-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer {
            _ = chmod(testDir.path, 0o700)
            try? FileManager.default.removeItem(at: testDir)
        }

        let testLogger = SessionLogger(supportDir: testDir)
        let sampleRoutine = Routine(key: "pt", title: "PT", subtitle: "Desk PT", estimatedMinutes: 2, exercises: [ExerciseCatalog.all[0]])
        let sampleRecord = SessionRecord(routine: sampleRoutine, checkedIDs: [ExerciseCatalog.all[0].id])

        // Revoke write permissions on the directory
        _ = chmod(testDir.path, 0o500) // r-x------

        var appendThrew = false
        do {
            try testLogger.append(sampleRecord)
        } catch {
            appendThrew = true
        }
        check("append throws SessionLoggerError on read-only directory", passed: appendThrew)

        var pendingThrew = false
        do {
            try testLogger.writePending([sampleRecord])
        } catch {
            pendingThrew = true
        }
        check("writePending throws SessionLoggerError on read-only directory", passed: pendingThrew)

        let sema = DispatchSemaphore(value: 0)
        var callbackResult: Result<SessionRecord, Error>? = nil
        testLogger.logCompletion(record: sampleRecord) { result in
            callbackResult = result
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 2.0)

        var failedSafely = false
        if case .failure = callbackResult {
            failedSafely = true
        }
        check("logCompletion reports failure callback on persistence error", passed: failedSafely)
        check("logCompletion never reports success on persistence error", passed: callbackResult != nil && failedSafely)

        _ = chmod(testDir.path, 0o700)
        return failures
    }

    // MARK: - Session Record Compatibility Cases

    private static func runSessionCompatibilityCases() -> Int {
        var failures = 0
        func check(_ name: String, passed: Bool, detail: String = "") {
            if !passed { failures += 1 }
            print("\(passed ? "✓" : "✗ FAIL")  \(name)")
            if !passed && !detail.isEmpty {
                print("      \(detail)")
            }
        }

        let sampleUUID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
        let sampleJSON = """
        {
            "id": "\(sampleUUID.uuidString)",
            "date": 748051200.0,
            "routineKey": "desk-pt",
            "routineTitle": "Desk PT",
            "exercisesCompleted": ["Chin Tucks", "Shoulder Rolls"],
            "completedCount": 2,
            "totalCount": 2,
            "estimatedMinutes": 3
        }
        """

        guard let data = sampleJSON.data(using: .utf8) else {
            check("sample JSON encoding", passed: false)
            return 1
        }

        do {
            let decoder = JSONDecoder()
            let record = try decoder.decode(SessionRecord.self, from: data)

            check("SessionRecord decodes legacy JSON id", passed: record.id == sampleUUID)
            check("SessionRecord decodes legacy JSON date", passed: record.date.timeIntervalSinceReferenceDate == 748051200.0)
            check("SessionRecord decodes legacy JSON routineKey", passed: record.routineKey == "desk-pt")
            check("SessionRecord decodes legacy JSON routineTitle", passed: record.routineTitle == "Desk PT")
            check("SessionRecord decodes legacy JSON completed exercises", passed: record.exercisesCompleted == ["Chin Tucks", "Shoulder Rolls"])
            check("SessionRecord decodes legacy JSON completedCount", passed: record.completedCount == 2)
            check("SessionRecord decodes legacy JSON totalCount", passed: record.totalCount == 2)
            check("SessionRecord decodes legacy JSON estimatedMinutes", passed: record.estimatedMinutes == 3)

            let encoder = JSONEncoder()
            let reencoded = try encoder.encode(record)
            let decodedAgain = try decoder.decode(SessionRecord.self, from: reencoded)
            check("SessionRecord round-trips identically", passed: decodedAgain.id == record.id && decodedAgain.completedCount == record.completedCount)
        } catch {
            check("SessionRecord decoding failed", passed: false, detail: "\(error)")
        }

        return failures
    }

    // MARK: - Automatic Update Trust Boundary & Verification Cases

    private static func runUpdateTrustCases() -> Int {
        var failures = 0
        func check(_ name: String, passed: Bool, detail: String = "") {
            if !passed { failures += 1 }
            print("\(passed ? "✓" : "✗ FAIL")  \(name)")
            if !passed && !detail.isEmpty {
                print("      \(detail)")
            }
        }

        // 1. Release Tag Validation
        let validTags = ["v1.1", "v1.2.0", "v2.0", "v10.12.3", "v0.1"]
        for tag in validTags {
            check("valid release tag '\(tag)' accepted", passed: ReleaseValidation.validateTag(tag))
        }

        let maliciousTags = [
            "../../evil",
            "v1.1/../../etc",
            "v1.1/escape",
            "../v1.2",
            "v1.1\\traversal",
            "v1.1\0null",
            "v1.1 ",
            " v1.1",
            "1.1",
            "v1",
            "v1.2.3.4",
            "v",
            "",
            "v1.1-beta",
            "v1.2.0?query=1",
            "v1.2.0#fragment"
        ]
        for tag in maliciousTags {
            check("malicious/invalid tag '\(tag)' rejected", passed: !ReleaseValidation.validateTag(tag))
        }

        // 2. Download URL Validation
        let expectedRepo = "mkny13/movebreak"
        let expectedTag = "v1.2.0"
        let expectedAsset = "MoveBreak.app.zip"

        let validURL = URL(string: "https://github.com/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip")!
        check(
            "valid release asset HTTPS URL accepted",
            passed: ReleaseValidation.validateDownloadURL(url: validURL, repo: expectedRepo, tag: expectedTag, assetName: expectedAsset)
        )

        let invalidURLs: [(String, String)] = [
            ("http://github.com/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip", "insecure HTTP scheme rejected"),
            ("https://evilgithub.com/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip", "deceptive host evilgithub.com rejected"),
            ("https://github.com.attacker.com/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip", "subdomain spoof rejected"),
            ("https://attacker.com/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip", "external host rejected"),
            ("https://github.com/otheruser/movebreak/releases/download/v1.2.0/MoveBreak.app.zip", "wrong repository owner rejected"),
            ("https://github.com/mkny13/otherrepo/releases/download/v1.2.0/MoveBreak.app.zip", "wrong repository name rejected"),
            ("https://github.com/mkny13/movebreak/releases/download/v1.3.0/MoveBreak.app.zip", "tag mismatch in download URL rejected"),
            ("https://github.com/mkny13/movebreak/releases/download/v1.2.0/Other.zip", "asset name mismatch rejected"),
            ("https://github.com:8443/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip", "non-standard port rejected"),
            ("https://user:pass@github.com/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip", "credentials in URL rejected"),
            ("https://github.com/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip?extra=1", "query parameters rejected"),
            ("https://github.com/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip#frag", "URL fragment rejected")
        ]
        for (rawURL, label) in invalidURLs {
            let url = URL(string: rawURL)!
            check(label, passed: !ReleaseValidation.validateDownloadURL(url: url, repo: expectedRepo, tag: expectedTag, assetName: expectedAsset))
        }

        // 3. Digest Parsing
        let validHex = "f8cbaae40ff571b5cf019035e90a601ea90efa3f3c6643a10b0726277dbd19a9"
        check(
            "valid sha256: digest parsed and lowercased",
            passed: ReleaseValidation.parseDigest("sha256:\(validHex.uppercased())") == validHex
        )

        let invalidDigests = [
            nil,
            "",
            "   ",
            "md5:f8cbaae40ff571b5cf019035e90a601e",
            "sha256:tooshort",
            "sha256:\(String(repeating: "a", count: 63))",
            "sha256:\(String(repeating: "a", count: 65))",
            "sha256:\(String(repeating: "g", count: 64))",
            validHex
        ]
        for (idx, raw) in invalidDigests.enumerated() {
            check("invalid digest format [\(idx)] rejected", passed: ReleaseValidation.parseDigest(raw) == nil)
        }

        // 4. Release Validation Helper (End-to-end Release JSON)
        let validReleaseJSON = """
        {
            "tag_name": "v1.2.0",
            "assets": [
                {
                    "name": "MoveBreak.app.zip",
                    "browser_download_url": "https://github.com/mkny13/movebreak/releases/download/v1.2.0/MoveBreak.app.zip",
                    "digest": "sha256:\(validHex)"
                }
            ]
        }
        """
        if let data = validReleaseJSON.data(using: .utf8),
           let rel = try? JSONDecoder().decode(GitHubRelease.self, from: data) {
            let candidate = try? ReleaseValidation.validateRelease(
                release: rel,
                repo: expectedRepo,
                assetName: expectedAsset,
                currentVersion: "1.1.0"
            )
            check("valid release metadata produces ReleaseCandidate", passed: candidate != nil && candidate?.tagName == "v1.2.0")

            var notNewerThrew = false
            do {
                _ = try ReleaseValidation.validateRelease(
                    release: rel,
                    repo: expectedRepo,
                    assetName: expectedAsset,
                    currentVersion: "1.2.0"
                )
            } catch let err as ReleaseValidationError {
                if case .notNewer = err { notNewerThrew = true }
            } catch {}
            check("older or equal release version rejected", passed: notNewerThrew)
        } else {
            check("validReleaseJSON decode", passed: false)
        }

        let missingAssetJSON = """
        {
            "tag_name": "v1.2.0",
            "assets": [
                {
                    "name": "other.zip",
                    "browser_download_url": "https://github.com/mkny13/movebreak/releases/download/v1.2.0/other.zip",
                    "digest": "sha256:\(validHex)"
                }
            ]
        }
        """
        if let data = missingAssetJSON.data(using: .utf8),
           let rel = try? JSONDecoder().decode(GitHubRelease.self, from: data) {
            var missingAssetThrew = false
            do {
                _ = try ReleaseValidation.validateRelease(
                    release: rel,
                    repo: expectedRepo,
                    assetName: expectedAsset,
                    currentVersion: "1.1.0"
                )
            } catch let err as ReleaseValidationError {
                if case .missingAsset = err { missingAssetThrew = true }
            } catch {}
            check("missing MoveBreak.app.zip asset rejected", passed: missingAssetThrew)
        }

        // 5. Archive SHA-256 Digest Verification & Tampering
        let tempFixtureDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("movebreak-update-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempFixtureDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFixtureDir) }

        let sampleArchiveURL = tempFixtureDir.appendingPathComponent("test.zip")
        let testPayload = Data("MoveBreakSecurePayloadData123456789".utf8)
        try? testPayload.write(to: sampleArchiveURL)

        if let computedHex = try? ArchiveDigestValidation.computeSHA256(at: sampleArchiveURL) {
            var verifyPassed = false
            do {
                try ArchiveDigestValidation.verifyArchive(at: sampleArchiveURL, expectedHexDigest: computedHex)
                verifyPassed = true
            } catch {}
            check("archive SHA-256 computation and matching verification succeed", passed: verifyPassed)

            var mismatchThrew = false
            let wrongHex = "0000000000000000000000000000000000000000000000000000000000000000"
            do {
                try ArchiveDigestValidation.verifyArchive(at: sampleArchiveURL, expectedHexDigest: wrongHex)
            } catch let err as ArchiveDigestError {
                if case .digestMismatch = err { mismatchThrew = true }
            } catch {}
            check("tampered archive / mismatched SHA-256 digest rejected before swap", passed: mismatchThrew)
        } else {
            check("computeSHA256 succeeded", passed: false)
        }

        // 6. Staging Directory Permissions (0700)
        let stagingDir = tempFixtureDir.appendingPathComponent("staging", isDirectory: true)
        do {
            try StagingPathValidation.ensureSecureDirectory(at: stagingDir)
            let mode = posixMode(at: stagingDir.path)
            check("staging directory enforced with mode 0700", passed: mode == 0o700, detail: "got \(String(format: "%o", mode ?? 0))")
        } catch {
            check("ensureSecureDirectory threw", passed: false, detail: "\(error)")
        }

        // 7. Staging Containment & Symlink Defense
        let appBundleDir = stagingDir.appendingPathComponent("MoveBreak.app", isDirectory: true)
        let macosDir = appBundleDir.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)
        let execURL = macosDir.appendingPathComponent("MoveBreak")
        FileManager.default.createFile(atPath: execURL.path, contents: Data([0xCF, 0xFA, 0xED, 0xFE]), attributes: [.posixPermissions: 0o755])

        var validContainment = false
        do {
            try StagingPathValidation.validateContainment(appURL: appBundleDir, stagingDir: stagingDir)
            validContainment = true
        } catch {}
        check("valid app bundle inside staging directory passes containment", passed: validContainment)

        let symlinkAppURL = stagingDir.appendingPathComponent("SymlinkEscape.app")
        try? FileManager.default.createSymbolicLink(at: symlinkAppURL, withDestinationURL: URL(fileURLWithPath: "/Applications"))
        var symlinkAppThrew = false
        do {
            try StagingPathValidation.validateContainment(appURL: symlinkAppURL, stagingDir: stagingDir)
        } catch let err as StagingPathError {
            if case .appIsSymlink = err { symlinkAppThrew = true }
        } catch {}
        check("symlinked app bundle pointing outside staging rejected", passed: symlinkAppThrew)

        let escapeSymlink = appBundleDir.appendingPathComponent("Contents/Resources/escape_link")
        let resourcesDir = appBundleDir.appendingPathComponent("Contents/Resources", isDirectory: true)
        try? FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: escapeSymlink, withDestinationURL: URL(fileURLWithPath: "/etc"))
        var internalSymlinkThrew = false
        do {
            try StagingPathValidation.validateContainment(appURL: appBundleDir, stagingDir: stagingDir)
        } catch let err as StagingPathError {
            if case .internalSymlinkEscapes = err { internalSymlinkThrew = true }
        } catch {}
        check("bundle with internal symlink escaping staging directory rejected", passed: internalSymlinkThrew)
        try? FileManager.default.removeItem(at: escapeSymlink)

        // 8. Bundle Metadata & Version Verification
        let plistURL = appBundleDir.appendingPathComponent("Contents/Info.plist")
        func writePlist(bundleID: String, executable: String, version: String) {
            let dict: [String: Any] = [
                "CFBundleIdentifier": bundleID,
                "CFBundleExecutable": executable,
                "CFBundleShortVersionString": version
            ]
            let data = try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try! data.write(to: plistURL)
        }

        writePlist(bundleID: "com.mike.movebreak", executable: "MoveBreak", version: "1.2.0")
        var metadataValid = false
        do {
            try BundleMetadataValidation.validateBundleMetadata(
                appURL: appBundleDir,
                expectedBundleID: "com.mike.movebreak",
                expectedExecutable: "MoveBreak",
                releaseTag: "v1.2.0"
            )
            metadataValid = true
        } catch {}
        check("matching bundle metadata (identifier, executable, version) passes", passed: metadataValid)

        writePlist(bundleID: "com.attacker.fakeapp", executable: "MoveBreak", version: "1.2.0")
        var bundleIDMismatchThrew = false
        do {
            try BundleMetadataValidation.validateBundleMetadata(
                appURL: appBundleDir,
                expectedBundleID: "com.mike.movebreak",
                expectedExecutable: "MoveBreak",
                releaseTag: "v1.2.0"
            )
        } catch let err as BundleMetadataError {
            if case .bundleIdentifierMismatch = err { bundleIDMismatchThrew = true }
        } catch {}
        check("mismatched bundle identifier rejected", passed: bundleIDMismatchThrew)

        writePlist(bundleID: "com.mike.movebreak", executable: "WrongExecutable", version: "1.2.0")
        var executableMismatchThrew = false
        do {
            try BundleMetadataValidation.validateBundleMetadata(
                appURL: appBundleDir,
                expectedBundleID: "com.mike.movebreak",
                expectedExecutable: "MoveBreak",
                releaseTag: "v1.2.0"
            )
        } catch let err as BundleMetadataError {
            if case .executableNameMismatch = err { executableMismatchThrew = true }
        } catch {}
        check("mismatched executable name rejected", passed: executableMismatchThrew)

        writePlist(bundleID: "com.mike.movebreak", executable: "MoveBreak", version: "1.1.0")
        var versionMismatchThrew = false
        do {
            try BundleMetadataValidation.validateBundleMetadata(
                appURL: appBundleDir,
                expectedBundleID: "com.mike.movebreak",
                expectedExecutable: "MoveBreak",
                releaseTag: "v1.2.0"
            )
        } catch let err as BundleMetadataError {
            if case .versionMismatch = err { versionMismatchThrew = true }
        } catch {}
        check("mismatched bundle version against release tag rejected", passed: versionMismatchThrew)

        // 9. Code Signing Policy & Leaf Certificate Verification
        let certBytesA = Data([0x30, 0x82, 0x01, 0x0A, 0x02, 0x01, 0x01])
        let certBytesB = Data([0x30, 0x82, 0x01, 0x0A, 0x02, 0x01, 0x02])

        let validRunningIdentity = CodeSigningIdentity(
            isAdHoc: false,
            bundleID: "com.mike.movebreak",
            leafCertificateData: certBytesA,
            leafCertificateSubject: "MoveBreak Signing"
        )
        let matchingCandidateIdentity = CodeSigningIdentity(
            isAdHoc: false,
            bundleID: "com.mike.movebreak",
            leafCertificateData: certBytesA,
            leafCertificateSubject: "MoveBreak Signing"
        )
        let differentCertCandidateIdentity = CodeSigningIdentity(
            isAdHoc: false,
            bundleID: "com.mike.movebreak",
            leafCertificateData: certBytesB,
            leafCertificateSubject: "Untrusted Developer Signing"
        )
        let adhocCandidateIdentity = CodeSigningIdentity(
            isAdHoc: true,
            bundleID: "com.mike.movebreak",
            leafCertificateData: nil,
            leafCertificateSubject: nil
        )
        let adhocRunningIdentity = CodeSigningIdentity(
            isAdHoc: true,
            bundleID: "com.mike.movebreak",
            leafCertificateData: nil,
            leafCertificateSubject: nil
        )

        var certMatchPassed = false
        do {
            try CodeSigningPolicy.verifySignerContinuity(running: validRunningIdentity, candidate: matchingCandidateIdentity)
            certMatchPassed = true
        } catch {}
        check("matching leaf signing certificate accepted", passed: certMatchPassed)

        var differentCertThrew = false
        do {
            try CodeSigningPolicy.verifySignerContinuity(running: validRunningIdentity, candidate: differentCertCandidateIdentity)
        } catch let err as SigningTrustError {
            if case .certificateMismatch = err { differentCertThrew = true }
        } catch {}
        check("differently signed candidate bundle rejected before swap", passed: differentCertThrew)

        var adhocCandidateThrew = false
        do {
            try CodeSigningPolicy.verifySignerContinuity(running: validRunningIdentity, candidate: adhocCandidateIdentity)
        } catch let err as SigningTrustError {
            if case .candidateAdHoc = err { adhocCandidateThrew = true }
        } catch {}
        check("ad-hoc candidate bundle rejected before swap", passed: adhocCandidateThrew)

        var adhocRunningThrew = false
        do {
            try CodeSigningPolicy.verifySignerContinuity(running: adhocRunningIdentity, candidate: matchingCandidateIdentity)
        } catch let err as SigningTrustError {
            if case .runningAppAdHoc = err { adhocRunningThrew = true }
        } catch {}
        check("ad-hoc running app disables automatic updates and fails closed", passed: adhocRunningThrew)

        // 10. Strict Code Signature Verification on Real Bundles
        let workspaceAppURL = URL(fileURLWithPath: "MoveBreak.app")
        if FileManager.default.fileExists(atPath: workspaceAppURL.path) {
            let inspected = CodeSigningPolicy.inspect(at: workspaceAppURL)
            if case .success(let identity) = inspected {
                check("workspace MoveBreak.app inspected accurately as ad-hoc signed", passed: identity.isAdHoc)
            } else {
                check("workspace MoveBreak.app inspected", passed: false)
            }

            var strictVerifyPassed = false
            do {
                try CodeSigningPolicy.verifyStrictCodeSignature(at: workspaceAppURL)
                strictVerifyPassed = true
            } catch {}
            check("strict code signature verification succeeds on un-tampered bundle", passed: strictVerifyPassed)
        }

        return failures
    }

    static func run() -> Never {
        var failures = 0
        print("MoveBreak — self-test")
        print(String(repeating: "─", count: 78))
        print("Serialized polling, pause/resume, and shutdown")
        failures += runSerializedPollingCases()
        print("")
        print("Deterministic debounce and session lifecycle")
        failures += runSessionLifecycleCases()
        print("")
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
        print("")
        print("Secret input, terminal echo suppression & redaction")
        failures += runSecretRedactionCases()
        print("")
        print("Keychain typed error handling, access class & isolation")
        failures += runKeychainCases()
        print("")
        print("Notion setup failure propagation & credential boundaries")
        failures += runNotionSetupCases()
        print("")
        print("Local session directory (0700) & file permissions (0600)")
        failures += runSessionLoggerPermissionCases()
        print("")
        print("Local session persistence failure observability")
        failures += runPersistenceFailureCases()
        print("")
        print("Session record JSON schema compatibility")
        failures += runSessionCompatibilityCases()
        print("")
        print("Automatic update trust boundary, staging containment & code signature verification")
        failures += runUpdateTrustCases()

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
