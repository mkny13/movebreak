import Darwin
import Foundation

enum SecuritySelfTests {
    private static func removeDefaultsDomain(
        _ defaults: UserDefaults,
        named suiteName: String,
        reporter: SelfTestReporter
    ) {
        defaults.removePersistentDomain(forName: suiteName)
        reporter.check(
            "isolated UserDefaults domain is removed",
            defaults.persistentDomain(forName: suiteName) == nil
        )
    }

    private static func runNumericPreferencesCases() -> Int {
        let reporter = SelfTestReporter()
        let suiteName = "com.mike.movebreak.tests.numeric.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            reporter.check("could not instantiate isolated UserDefaults suite", false)
            return reporter.failureCount
        }
        reporter.check("numeric preferences domain starts absent", testDefaults.persistentDomain(forName: suiteName) == nil)

        Preferences.withDefaults(testDefaults) {
            // Unconfigured values fall back to documented safe defaults
            reporter.check("default pollInterval", expected: Preferences.defaultPollInterval, actual: Preferences.pollInterval)
            reporter.check("default debouncePolls", expected: Preferences.defaultDebouncePolls, actual: Preferences.debouncePolls)
            reporter.check("default sessionEndGrace", expected: Preferences.defaultSessionEndGrace, actual: Preferences.sessionEndGrace)
            reporter.check("default declineCooldown", expected: Preferences.defaultDeclineCooldown, actual: Preferences.declineCooldown)
            reporter.check("default timeoutCooldown", expected: Preferences.defaultTimeoutCooldown, actual: Preferences.timeoutCooldown)
            reporter.check("default promptTimeout", expected: Preferences.defaultPromptTimeout, actual: Preferences.promptTimeout)
            reporter.check("default tabCacheLifetime", expected: Preferences.defaultTabCacheLifetime, actual: Preferences.tabCacheLifetime)

            // pollInterval bounds [0.5 ... 60.0]
            testDefaults.set(-1.0, forKey: "pollInterval")
            reporter.check("pollInterval negative falls back", expected: Preferences.defaultPollInterval, actual: Preferences.pollInterval)
            testDefaults.set(0.0, forKey: "pollInterval")
            reporter.check("pollInterval zero falls back", expected: Preferences.defaultPollInterval, actual: Preferences.pollInterval)
            testDefaults.set(0.1, forKey: "pollInterval")
            reporter.check("pollInterval below min (0.1) falls back", expected: Preferences.defaultPollInterval, actual: Preferences.pollInterval)
            testDefaults.set(100.0, forKey: "pollInterval")
            reporter.check("pollInterval above max (100.0) falls back", expected: Preferences.defaultPollInterval, actual: Preferences.pollInterval)
            testDefaults.set(Double.nan, forKey: "pollInterval")
            reporter.check("pollInterval NaN falls back", expected: Preferences.defaultPollInterval, actual: Preferences.pollInterval)
            testDefaults.set(Double.infinity, forKey: "pollInterval")
            reporter.check("pollInterval +Inf falls back", expected: Preferences.defaultPollInterval, actual: Preferences.pollInterval)
            testDefaults.set(-Double.infinity, forKey: "pollInterval")
            reporter.check("pollInterval -Inf falls back", expected: Preferences.defaultPollInterval, actual: Preferences.pollInterval)
            testDefaults.set("not-a-number", forKey: "pollInterval")
            reporter.check("pollInterval malformed string falls back", expected: Preferences.defaultPollInterval, actual: Preferences.pollInterval)
            testDefaults.set(5.0, forKey: "pollInterval")
            reporter.check("pollInterval valid in-range accepted", expected: 5.0, actual: Preferences.pollInterval)

            // debouncePolls bounds [1 ... 20]
            testDefaults.set(0, forKey: "debouncePolls")
            reporter.check("debouncePolls zero falls back", expected: Preferences.defaultDebouncePolls, actual: Preferences.debouncePolls)
            testDefaults.set(-5, forKey: "debouncePolls")
            reporter.check("debouncePolls negative falls back", expected: Preferences.defaultDebouncePolls, actual: Preferences.debouncePolls)
            testDefaults.set(50, forKey: "debouncePolls")
            reporter.check("debouncePolls above max falls back", expected: Preferences.defaultDebouncePolls, actual: Preferences.debouncePolls)
            testDefaults.set("invalid", forKey: "debouncePolls")
            reporter.check("debouncePolls invalid string falls back", expected: Preferences.defaultDebouncePolls, actual: Preferences.debouncePolls)
            testDefaults.set(4, forKey: "debouncePolls")
            reporter.check("debouncePolls valid accepted", expected: 4, actual: Preferences.debouncePolls)

            // sessionEndGrace bounds [5.0 ... 600.0]
            testDefaults.set(0.0, forKey: "sessionEndGrace")
            reporter.check("sessionEndGrace zero falls back", expected: Preferences.defaultSessionEndGrace, actual: Preferences.sessionEndGrace)
            testDefaults.set(2.0, forKey: "sessionEndGrace")
            reporter.check("sessionEndGrace below min falls back", expected: Preferences.defaultSessionEndGrace, actual: Preferences.sessionEndGrace)
            testDefaults.set(1000.0, forKey: "sessionEndGrace")
            reporter.check("sessionEndGrace above max falls back", expected: Preferences.defaultSessionEndGrace, actual: Preferences.sessionEndGrace)
            testDefaults.set(120.0, forKey: "sessionEndGrace")
            reporter.check("sessionEndGrace valid accepted", expected: 120.0, actual: Preferences.sessionEndGrace)

            // declineCooldown bounds [60.0 ... 86400.0]
            testDefaults.set(10.0, forKey: "declineCooldown")
            reporter.check("declineCooldown below min falls back", expected: Preferences.defaultDeclineCooldown, actual: Preferences.declineCooldown)
            testDefaults.set(200000.0, forKey: "declineCooldown")
            reporter.check("declineCooldown above max falls back", expected: Preferences.defaultDeclineCooldown, actual: Preferences.declineCooldown)
            testDefaults.set(1800.0, forKey: "declineCooldown")
            reporter.check("declineCooldown valid accepted", expected: 1800.0, actual: Preferences.declineCooldown)

            // timeoutCooldown bounds [60.0 ... 86400.0]
            testDefaults.set(-10.0, forKey: "timeoutCooldown")
            reporter.check("timeoutCooldown negative falls back", expected: Preferences.defaultTimeoutCooldown, actual: Preferences.timeoutCooldown)
            testDefaults.set(600.0, forKey: "timeoutCooldown")
            reporter.check("timeoutCooldown valid accepted", expected: 600.0, actual: Preferences.timeoutCooldown)

            // promptTimeout bounds [5.0 ... 300.0]
            testDefaults.set(1.0, forKey: "promptTimeout")
            reporter.check("promptTimeout below min falls back", expected: Preferences.defaultPromptTimeout, actual: Preferences.promptTimeout)
            testDefaults.set(500.0, forKey: "promptTimeout")
            reporter.check("promptTimeout above max falls back", expected: Preferences.defaultPromptTimeout, actual: Preferences.promptTimeout)
            testDefaults.set(45.0, forKey: "promptTimeout")
            reporter.check("promptTimeout valid accepted", expected: 45.0, actual: Preferences.promptTimeout)

            // tabCacheLifetime bounds [1.0 ... 60.0]
            testDefaults.set(0.1, forKey: "tabCacheLifetime")
            reporter.check("tabCacheLifetime below min falls back", expected: Preferences.defaultTabCacheLifetime, actual: Preferences.tabCacheLifetime)
            testDefaults.set(120.0, forKey: "tabCacheLifetime")
            reporter.check("tabCacheLifetime above max falls back", expected: Preferences.defaultTabCacheLifetime, actual: Preferences.tabCacheLifetime)
            testDefaults.set(10.0, forKey: "tabCacheLifetime")
            reporter.check("tabCacheLifetime valid accepted", expected: 10.0, actual: Preferences.tabCacheLifetime)
        }

        removeDefaultsDomain(testDefaults, named: suiteName, reporter: reporter)

        return reporter.failureCount
    }

    // MARK: - List Normalization Regression Cases

    private static func runListNormalizationCases() -> Int {
        let reporter = SelfTestReporter()
        let suiteName = "com.mike.movebreak.tests.list.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            reporter.check("could not instantiate isolated UserDefaults suite", false)
            return reporter.failureCount
        }
        reporter.check("list preferences domain starts absent", testDefaults.persistentDomain(forName: suiteName) == nil)

        Preferences.withDefaults(testDefaults) {
            // Empty array falls back to default
            testDefaults.set([] as [String], forKey: "videoPatterns")
            reporter.check("empty list falls back", expected: Preferences.defaultVideoPatterns, actual: Preferences.videoPatterns)

            // Array of blanks falls back to default
            testDefaults.set(["", "   ", "\t\n"], forKey: "videoPatterns")
            reporter.check("blanks list falls back", expected: Preferences.defaultVideoPatterns, actual: Preferences.videoPatterns)

            // Oversized entries (> 256 chars) dropped
            let oversized = String(repeating: "a", count: 300)
            testDefaults.set([oversized], forKey: "videoPatterns")
            reporter.check("oversized entries list falls back", expected: Preferences.defaultVideoPatterns, actual: Preferences.videoPatterns)

            // Trimming, scheme stripping, deduplication preserving order
            testDefaults.set([
                "  https://vimeo.com  ",
                "twitch.tv",
                "vimeo.com",
                "   ",
                "http://coursera.org/lecture",
                "twitch.tv",
            ], forKey: "videoPatterns")
            reporter.check(
                "deduplication and trimming of URL patterns",
                expected: ["vimeo.com", "twitch.tv", "coursera.org/lecture"],
                actual: Preferences.videoPatterns
            )

            // Cap at maxListCount (100)
            let many = (1...150).map { "site\($0).org/video" }
            testDefaults.set(many, forKey: "videoPatterns")
            reporter.check("capped at maxListCount (100)", expected: Preferences.maxListCount, actual: Preferences.videoPatterns.count)

            // Bundle ID normalization: trim, drop invalid characters/spaces, deduplicate
            testDefaults.set([
                "",
                "  com.custom.app  ",
                "com.custom.app",
                "invalid bundle with spaces",
                "invalid/bundle",
                oversized,
            ], forKey: "ignoredApps")
            reporter.check(
                "bundle ID normalization and invalid character dropping",
                expected: Set(["com.custom.app"]),
                actual: Preferences.ignoredApps
            )
        }


        removeDefaultsDomain(testDefaults, named: suiteName, reporter: reporter)

        return reporter.failureCount
    }

    // MARK: - URL Host Boundary Regression Cases

    private static func runHostBoundaryCases() -> Int {
        let reporter = SelfTestReporter()

        func checkMatch(_ url: String, pattern: String, expected: Bool, name: String) {
            let actual = BrowserTabInspector.matches(url, [pattern])
            let passed = actual == expected
            reporter.check(
                name,
                passed,
                detail: "URL: \(url), pattern: \(pattern), expected \(expected), got \(actual)"
            )
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

        return reporter.failureCount
    }

    // MARK: - Ignored Apps Precedence Regression Cases

    private static func runIgnoredAppsPrecedenceCases() -> Int {
        let reporter = SelfTestReporter()

        func checkIgnored(
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
            var details: [String] = []
            if !statePassed {
                details.append("expected state \(expectedState), got \(classification.state) (\(classification.reason))")
            }
            if !inspectorPassed {
                details.append("expected tabInspector called: \(expectInspectorCalled), actual: \(inspectorCalled)")
            }
            reporter.record(name, passed: passed, details: details)
        }

        // Stage 1 (Mic): Ignored app with live mic is NOT a meeting
        checkIgnored(
            name: "ignored app holding mic is idle",
            processes: [AudioProcess(bundleID: "com.spotify.client", isRunningInput: true)],
            ignoredApps: ["com.spotify.client"],
            meetingApps: ["com.spotify.client", "us.zoom.xos"],
            expectedState: .idle
        )

        // Stage 1 (Mic): Ignored app helper holding mic is NOT a meeting
        checkIgnored(
            name: "ignored app helper holding mic is idle",
            processes: [AudioProcess(bundleID: "com.spotify.client.helper", isRunningInput: true)],
            ignoredApps: ["com.spotify.client"],
            meetingApps: ["com.spotify.client", "us.zoom.xos"],
            expectedState: .idle
        )

        // Stage 2 (Player): Ignored native player holding output is NOT video
        checkIgnored(
            name: "ignored native player holding output is idle",
            processes: [AudioProcess(bundleID: "org.videolan.vlc", isRunningOutput: true)],
            ignoredApps: ["org.videolan.vlc"],
            nativePlayers: ["org.videolan.vlc"],
            expectedState: .idle
        )

        // Stage 2 (Player): Ignored native player helper holding output is NOT video
        checkIgnored(
            name: "ignored native player helper holding output is idle",
            processes: [AudioProcess(bundleID: "org.videolan.vlc.helper", isRunningOutput: true)],
            ignoredApps: ["org.videolan.vlc"],
            nativePlayers: ["org.videolan.vlc"],
            expectedState: .idle
        )

        // Stage 3 (Browser): Ignored browser holding output does NOT trigger AppleScript or video
        checkIgnored(
            name: "ignored browser holding output is idle and tab inspection never runs",
            processes: [AudioProcess(bundleID: "com.google.Chrome", isRunningOutput: true)],
            ignoredApps: ["com.google.Chrome"],
            browsers: ["com.google.Chrome"],
            expectedState: .idle,
            expectInspectorCalled: false
        )

        // Stage 3 (Browser): Ignored browser helper holding output does NOT trigger AppleScript
        checkIgnored(
            name: "ignored browser helper holding output is idle and tab inspection never runs",
            processes: [AudioProcess(bundleID: "com.google.Chrome.helper", isRunningOutput: true)],
            ignoredApps: ["com.google.Chrome"],
            browsers: ["com.google.Chrome"],
            expectedState: .idle,
            expectInspectorCalled: false
        )

        // Stage 3 (Safari GPU helper): Safari in ignoredApps suppresses com.apple.WebKit.GPU
        checkIgnored(
            name: "Safari in ignoredApps suppresses WebKit GPU process",
            processes: [AudioProcess(bundleID: "com.apple.WebKit.GPU", isRunningOutput: true)],
            ignoredApps: ["com.apple.Safari"],
            browsers: ["com.apple.Safari"],
            expectedState: .idle,
            expectInspectorCalled: false
        )

        // Contrast: Non-ignored browser holding output DOES trigger inspection
        checkIgnored(
            name: "non-ignored browser holding output triggers inspection",
            processes: [AudioProcess(bundleID: "com.google.Chrome.helper", isRunningOutput: true)],
            ignoredApps: ["com.spotify.client"],
            browsers: ["com.google.Chrome"],
            expectedState: .video,
            expectInspectorCalled: true
        )

        return reporter.failureCount
    }

    // MARK: - Unsupported Browser Security Regression Cases

    private static func runUnsupportedBrowserCases() -> Int {
        let reporter = SelfTestReporter()
        let suiteName = "com.mike.movebreak.tests.browser.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            reporter.check("could not instantiate isolated UserDefaults suite", false)
            return reporter.failureCount
        }
        reporter.check("browser preferences domain starts absent", testDefaults.persistentDomain(forName: suiteName) == nil)

        Preferences.withDefaults(testDefaults) {
            // Attempting to configure an unsupported browser is rejected
            testDefaults.set(["com.unsupported.browser", "com.malicious.app"], forKey: "browsers")
            reporter.check(
                "unsupported browsers rejected; falls back to default supported browsers",
                expected: Preferences.defaultBrowsers,
                actual: Preferences.browsers
            )

            // Configuring a mix of supported and unsupported keeps only supported
            testDefaults.set(["com.google.Chrome", "com.malicious.app"], forKey: "browsers")
            reporter.check(
                "mix of supported and unsupported keeps only supported",
                expected: Set(["com.google.Chrome"]),
                actual: Preferences.browsers
            )
        }

        // BrowserTabInspector support verification
        reporter.check(
            "Chrome is supported",
            expected: true,
            actual: BrowserTabInspector.isBrowserSupported(bundleID: "com.google.Chrome")
        )
        reporter.check(
            "Safari is supported",
            expected: true,
            actual: BrowserTabInspector.isBrowserSupported(bundleID: "com.apple.Safari")
        )
        reporter.check(
            "Arbitrary app is NOT supported",
            expected: false,
            actual: BrowserTabInspector.isBrowserSupported(bundleID: "com.malicious.app")
        )
        reporter.check(
            "Firefox is NOT supported (no AppleScript tab dictionary)",
            expected: false,
            actual: BrowserTabInspector.isBrowserSupported(bundleID: "org.mozilla.firefox")
        )

        // Inspecting an unsupported browser returns unknown and never runs AppleScript
        let inspector = BrowserTabInspector()
        let inspection = inspector.inspectFresh(bundleID: "com.malicious.app")
        reporter.check(
            "inspecting unsupported browser returns unknown verdict",
            expected: TabVerdict.unknown,
            actual: inspection.verdict
        )
        reporter.check(
            "inspecting unsupported browser gives unsupported reason",
            expected: "no AppleScript tab support for this browser",
            actual: inspection.reason
        )
        reporter.check(
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
        reporter.check(
            "unsupported browser stream results in idle state",
            expected: SessionState.idle,
            actual: classification.state
        )
        reporter.check(
            "inspector was called safely without error",
            expected: true,
            actual: inspectorInvoked
        )

        removeDefaultsDomain(testDefaults, named: suiteName, reporter: reporter)

        return reporter.failureCount
    }

    // MARK: - Video vs Music Tab Classification Cases

    // MARK: - Secret Input, Terminal Echo Suppression & Redaction Cases

    private static func runSecretRedactionCases() -> Int {
        let reporter = SelfTestReporter()

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
            reporter.check("KeychainError does not leak secret in description", passed: !desc.contains(sentinelToken))
        }

        // 2. Interactive PTY terminal echo suppression
        var master: Int32 = 0
        var slave: Int32 = 0
        if openpty(&master, &slave, nil, nil, nil) == 0 {
            let secretPayload = "sentinel_pty_secret_pass\n"
            let bytesWritten = secretPayload.withCString {
                write(master, $0, secretPayload.utf8.count)
            }
            reporter.check("PTY secret fixture is written completely", bytesWritten == secretPayload.utf8.count)
            let result: (Bool, String?, Bool)?
            do {
                result = try SelfTestSupport.withStandardInput(from: slave) {
                    var before = termios()
                    let readBefore = tcgetattr(STDIN_FILENO, &before) == 0
                    let echoEnabledInitially = readBefore && (before.c_lflag & tcflag_t(ECHO)) != 0
                    let readValue = SecretInput.readSecret(prompt: nil)
                    var after = termios()
                    let readAfter = tcgetattr(STDIN_FILENO, &after) == 0
                    let echoRestoredAfterwards = readAfter && (after.c_lflag & tcflag_t(ECHO)) != 0
                    return (echoEnabledInitially, readValue, echoRestoredAfterwards)
                }
            } catch {
                result = nil
                reporter.check("PTY stdin redirection infrastructure succeeds", false, detail: "\(error)")
            }
            close(slave)

            var echoedBytes = [UInt8](repeating: 0, count: 512)
            let flags = fcntl(master, F_GETFL, 0)
            _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
            let n = read(master, &echoedBytes, echoedBytes.count)
            close(master)

            let echoedString = n > 0 ? (String(bytes: echoedBytes[0..<n], encoding: .utf8) ?? "") : ""

            reporter.check("PTY slave has echo initially", passed: result?.0 == true)
            reporter.check("readSecret accurately reads secret from terminal", passed: result?.1 == "sentinel_pty_secret_pass")
            reporter.check("readSecret does NOT echo secret back to terminal", passed: !echoedString.contains("sentinel_pty_secret_pass"))
            reporter.check("readSecret restores terminal echo after reading", passed: result?.2 == true)
        } else {
            reporter.check("openpty available for echo testing", passed: false, detail: "openpty failed")
        }

        // 3. SecretInput non-interactive pipe reader
        var pipeFds: [Int32] = [0, 0]
        if pipe(&pipeFds) == 0 {
            let testInput = "noninteractive_secret_123\n"
            let bytesWritten = testInput.withCString {
                write(pipeFds[1], $0, testInput.utf8.count)
            }
            reporter.check("pipe secret fixture is written completely", bytesWritten == testInput.utf8.count)
            close(pipeFds[1])
            let pipeRead: String?
            do {
                pipeRead = try SelfTestSupport.withStandardInput(from: pipeFds[0]) {
                    SecretInput.readSecret(prompt: nil)
                }
            } catch {
                pipeRead = nil
                reporter.check("pipe stdin redirection infrastructure succeeds", false, detail: "\(error)")
            }
            close(pipeFds[0])

            reporter.check("non-interactive pipe input reads accurately", passed: pipeRead == "noninteractive_secret_123")
        } else {
            reporter.check("pipe available for non-interactive input testing", passed: false)
        }

        // A redirection failure must throw, skip the body, restore stdin, and close its saved copy.
        let descriptorsBeforeFailure = SelfTestSupport.openFileDescriptorCount()
        var invalidRedirectionThrew = false
        var invalidBodyRan = false
        do {
            _ = try SelfTestSupport.withStandardInput(from: -1) {
                invalidBodyRan = true
            }
        } catch {
            invalidRedirectionThrew = true
        }
        let descriptorsAfterFailure = SelfTestSupport.openFileDescriptorCount()
        reporter.check(
            "stdin redirection failure is observable and leak-free",
            invalidRedirectionThrew && !invalidBodyRan && descriptorsAfterFailure == descriptorsBeforeFailure,
            detail: "before=\(descriptorsBeforeFailure), after=\(descriptorsAfterFailure)"
        )

        let descriptorsBeforeBodyFailure = SelfTestSupport.openFileDescriptorCount()
        var throwingPipe: [Int32] = [-1, -1]
        if pipe(&throwingPipe) == 0 {
            close(throwingPipe[1])
            var bodyFailureObserved = false
            do {
                _ = try SelfTestSupport.withStandardInput(from: throwingPipe[0]) {
                    throw NSError(domain: "SelfTestExpectedInputBodyFailure", code: 1)
                }
            } catch {
                bodyFailureObserved = true
            }
            close(throwingPipe[0])
            let descriptorsAfterBodyFailure = SelfTestSupport.openFileDescriptorCount()
            reporter.check(
                "stdin body failure restores input and descriptor baseline",
                bodyFailureObserved && descriptorsAfterBodyFailure == descriptorsBeforeBodyFailure,
                detail: "before=\(descriptorsBeforeBodyFailure), after=\(descriptorsAfterBodyFailure)"
            )
        } else {
            reporter.check("pipe available for stdin body-failure testing", false)
        }

        // 4. CLI Argument check: verify rejection of secret argument flags
        let forbiddenFlags = ["--token", "--token=secret123", "--secret", "--notion-token", "--api-key"]
        for flag in forbiddenFlags {
            let isRejected = flag.hasPrefix("--token") || flag.hasPrefix("--secret") || flag.hasPrefix("--notion-token") || flag.hasPrefix("--api-key")
            reporter.check("CLI argument '\(flag)' rejected from process arguments", passed: isRejected)
        }

        return reporter.failureCount
    }

    static func run() -> Int {
        var failures = 0
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
        print("Secret input, terminal echo suppression & redaction")
        failures += runSecretRedactionCases()
        return failures
    }
}
