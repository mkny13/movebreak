import Darwin
import Foundation

enum DetectionSelfTests {
    private final class TestClock {
        var current = Date(timeIntervalSince1970: 1_000)

        func advance(_ interval: TimeInterval) {
            current = current.addingTimeInterval(interval)
        }
    }

    // MARK: - Serialized Polling and Lifecycle Cases

    private static func runSerializedPollingCases() -> Int {
        let reporter = SelfTestReporter()

        let callbackQueue = DispatchQueue(label: "com.mike.movebreak.tests.poll-callback")
        let workerQueue = DispatchQueue(label: "com.mike.movebreak.tests.poll-worker")
        let scheduler = SerialPollScheduler(
            queue: workerQueue,
            completionQueue: callbackQueue
        )
        let countsLock = NSLock()
        var invocationCount = 0
        var activeCount = 0
        var maximumActiveCount = 0
        var acceptedCount = 0
        var firstReleaseSucceeded = false
        var pausedReleaseSucceeded = false
        var ordering: [String] = []

        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstCompleted = DispatchSemaphore(value: 0)
        let releasePaused = DispatchSemaphore(value: 0)
        defer {
            // A failed assertion must never leave either synthetic inspector blocked.
            releaseFirst.signal()
            releasePaused.signal()
            scheduler.shutdown()
            workerQueue.sync {}
            callbackQueue.sync {}
        }

        scheduler.resume()
        let firstScheduled = scheduler.request(
            inspect: {
                countsLock.withLock {
                    invocationCount += 1
                    activeCount += 1
                    maximumActiveCount = max(maximumActiveCount, activeCount)
                }
                firstStarted.signal()
                let releaseResult = releaseFirst.wait(timeout: .now() + 5)
                countsLock.withLock {
                    firstReleaseSucceeded = releaseResult == .success
                    activeCount -= 1
                }
                return 1
            },
            accept: { value in
                countsLock.withLock {
                    acceptedCount += 1
                    ordering.append("accepted")
                }
                return value
            },
            completion: { _ in firstCompleted.signal() }
        )
        reporter.check("first poll is scheduled", firstScheduled)
        let firstStartResult = firstStarted.wait(timeout: .now() + 5)
        reporter.check(
            "slow synthetic inspector starts",
            firstStartResult == .success,
            detail: "inspector start wait timed out"
        )

        let skipped = (0..<100).filter { _ in
            !scheduler.request(inspect: { 99 }, accept: { $0 }, completion: { _ in })
        }.count
        reporter.check("ticks are skipped while a poll is in flight", skipped == 100)
        reporter.check("slow ticks never overlap", countsLock.withLock { invocationCount == 1 && maximumActiveCount == 1 })

        let mutationRan = DispatchSemaphore(value: 0)
        scheduler.perform {
            countsLock.withLock { ordering.append("mutation") }
            mutationRan.signal()
        }
        releaseFirst.signal()
        let firstCompletionResult = firstCompleted.wait(timeout: .now() + 5)
        reporter.check(
            "accepted poll completes",
            firstCompletionResult == .success,
            detail: "completion wait timed out"
        )
        let mutationResult = mutationRan.wait(timeout: .now() + 5)
        reporter.check(
            "queued detector mutation runs",
            mutationResult == .success,
            detail: "worker queue did not drain"
        )
        reporter.check(
            "synthetic inspector is released",
            countsLock.withLock { firstReleaseSucceeded },
            detail: "inspector release wait timed out"
        )
        reporter.check(
            "detector mutations wait behind an in-flight poll",
            countsLock.withLock { ordering == ["accepted", "mutation"] },
            detail: "observed order: \(countsLock.withLock { ordering })"
        )

        let secondCompleted = DispatchSemaphore(value: 0)
        reporter.check(
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
        let secondCompletionResult = secondCompleted.wait(timeout: .now() + 5)
        reporter.check(
            "second poll completes",
            secondCompletionResult == .success,
            detail: "completion wait timed out"
        )

        let pausedStarted = DispatchSemaphore(value: 0)
        var pausedCompletionCount = 0
        let pausedScheduled = scheduler.request(
            inspect: {
                pausedStarted.signal()
                let releaseResult = releasePaused.wait(timeout: .now() + 5)
                countsLock.withLock { pausedReleaseSucceeded = releaseResult == .success }
                return 3
            },
            accept: { value in
                countsLock.withLock { acceptedCount += 1 }
                return value
            },
            completion: { _ in countsLock.withLock { pausedCompletionCount += 1 } }
        )
        reporter.check("pre-pause poll is scheduled", pausedScheduled)
        let pausedStartResult = pausedStarted.wait(timeout: .now() + 5)
        reporter.check(
            "pre-pause poll starts",
            pausedStartResult == .success,
            detail: "inspector start wait timed out"
        )
        scheduler.pause()
        releasePaused.signal()
        let workerDrained = DispatchSemaphore(value: 0)
        scheduler.perform { workerDrained.signal() }
        let workerDrainResult = workerDrained.wait(timeout: .now() + 5)
        reporter.check(
            "pre-pause poll drains after release",
            workerDrainResult == .success,
            detail: "worker queue barrier timed out"
        )
        let callbackDrained = DispatchSemaphore(value: 0)
        callbackQueue.async { callbackDrained.signal() }
        let callbackDrainResult = callbackDrained.wait(timeout: .now() + 5)
        reporter.check(
            "pre-pause callback queue drains",
            callbackDrainResult == .success,
            detail: "callback queue barrier timed out"
        )
        reporter.check(
            "pre-pause synthetic inspector is released",
            countsLock.withLock { pausedReleaseSucceeded },
            detail: "inspector release wait timed out"
        )
        reporter.check(
            "pause invalidates an in-flight result",
            countsLock.withLock { pausedCompletionCount == 0 },
            detail: "completion count: \(countsLock.withLock { pausedCompletionCount })"
        )
        reporter.check("pause prevents stale lifecycle acceptance", countsLock.withLock { acceptedCount == 2 })
        reporter.check("paused scheduler rejects ticks", !scheduler.request(inspect: { 4 }, accept: { $0 }, completion: { _ in }))

        scheduler.resume()
        let resumed = DispatchSemaphore(value: 0)
        reporter.check(
            "resume accepts new ticks",
            scheduler.request(inspect: { 5 }, accept: { $0 }, completion: { _ in resumed.signal() })
        )
        let resumedResult = resumed.wait(timeout: .now() + 5)
        reporter.check(
            "resumed poll completes",
            resumedResult == .success,
            detail: "completion wait timed out"
        )

        scheduler.shutdown()
        reporter.check("shutdown permanently rejects ticks", !scheduler.request(inspect: { 6 }, accept: { $0 }, completion: { _ in }))
        return reporter.failureCount
    }

    private static func runSessionLifecycleCases() -> Int {
        let reporter = SelfTestReporter()

        let configuration = SessionLifecycle.Configuration(
            debouncePolls: 2,
            sessionEndGrace: 10,
            declineCooldown: 30,
            timeoutCooldown: 15
        )
        let clock = TestClock()
        var lifecycle = SessionLifecycle(configuration: configuration) { clock.current }

        reporter.check("first active sample is debounced", lifecycle.observe(.meeting) == nil && lifecycle.state == .idle)
        reporter.check("second active sample starts and prompts session", lifecycle.observe(.meeting) == .meeting && lifecycle.sessionID == 1)
        reporter.check("stable active state does not prompt twice", lifecycle.observe(.meeting) == nil)
        reporter.check("meeting-to-video candidate is debounced", lifecycle.observe(.video) == nil && lifecycle.state == .meeting)
        reporter.check("meeting-to-video stays one continuous session", lifecycle.observe(.video) == nil && lifecycle.state == .video && lifecycle.sessionID == 1)

        _ = lifecycle.observe(.idle)
        _ = lifecycle.observe(.idle)
        clock.advance(5)
        _ = lifecycle.observe(.meeting)
        reporter.check("activity returning inside idle grace does not re-prompt", lifecycle.observe(.meeting) == nil && lifecycle.sessionID == 1)

        _ = lifecycle.observe(.idle)
        _ = lifecycle.observe(.idle)
        clock.advance(11)
        _ = lifecycle.observe(.idle)
        _ = lifecycle.observe(.meeting)
        reporter.check("activity after idle grace starts a new session", lifecycle.observe(.meeting) == .meeting && lifecycle.sessionID == 2)

        lifecycle.recordDecline()
        _ = lifecycle.observe(.idle)
        _ = lifecycle.observe(.idle)
        clock.advance(11)
        _ = lifecycle.observe(.idle)
        _ = lifecycle.observe(.meeting)
        reporter.check("decline cooldown suppresses a new session", lifecycle.observe(.meeting) == nil && lifecycle.sessionID == 3)
        clock.advance(20)
        reporter.check("active session prompts when decline cooldown expires", lifecycle.observe(.meeting) == .meeting)

        let timeoutClock = TestClock()
        var timeoutLifecycle = SessionLifecycle(configuration: configuration) { timeoutClock.current }
        _ = timeoutLifecycle.observe(.video)
        reporter.check("video session initially prompts", timeoutLifecycle.observe(.video) == .video)
        timeoutLifecycle.recordTimeout()
        _ = timeoutLifecycle.observe(.idle)
        _ = timeoutLifecycle.observe(.idle)
        timeoutClock.advance(11)
        _ = timeoutLifecycle.observe(.idle)
        _ = timeoutLifecycle.observe(.video)
        reporter.check("timeout cooldown suppresses a new session", timeoutLifecycle.observe(.video) == nil)
        timeoutClock.advance(5)
        reporter.check("active session prompts when timeout cooldown expires", timeoutLifecycle.observe(.video) == .video)

        return reporter.failureCount
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

        let reporter = SelfTestReporter()
        for testCase in cases {
            let actual = BundleIdentity.owner(of: testCase.process, in: testCase.set)
            let passed = actual == testCase.expected
            reporter.check(
                testCase.process,
                passed,
                detail: "expected \(testCase.expected ?? "no match"), got \(actual ?? "no match")"
            )
        }
        return reporter.failureCount
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
        let reporter = SelfTestReporter()

        var seen: Set<String> = []
        for exercise in ExerciseCatalog.all {
            if seen.contains(exercise.id) {
                reporter.check("duplicate catalog id \"\(exercise.id)\" (from \"\(exercise.name)\")", false)
            }
            seen.insert(exercise.id)
        }
        if reporter.failureCount == 0 {
            reporter.check("\(ExerciseCatalog.all.count) catalog exercises, all ids unique", true)
        }

        for seed in RoutineStore.defaultSeeds {
            let missing = seed.exerciseIDs.filter { ExerciseCatalog.exercise(id: $0) == nil }
            reporter.check(
                "seed \"\(seed.name)\" resolves all \(seed.exerciseIDs.count) picks",
                missing.isEmpty,
                detail: "missing catalog ids: \(missing)"
            )
        }

        return reporter.failureCount
    }

    // MARK: - Numeric Preferences Regression Cases

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

        let reporter = SelfTestReporter()
        for testCase in cases {
            let (verdict, reason) = BrowserTabInspector.classify(
                activeURL: testCase.activeURL, allURLs: testCase.allURLs
            )
            let passed = verdict.isVideo == testCase.expectVideo
                && verdict.isMeeting == testCase.expectMeeting
            func label(video: Bool, meeting: Bool) -> String {
                if meeting { return "MEETING" }
                if video { return "VIDEO" }
                return "no prompt"
            }

            reporter.record(
                testCase.name,
                passed: passed,
                details: [
                    "expected \(label(video: testCase.expectVideo, meeting: testCase.expectMeeting)), "
                        + "got \(label(video: verdict.isVideo, meeting: verdict.isMeeting)) — \(reason)"
                ],
                alwaysShowDetails: true
            )
        }
        return reporter.failureCount
    }


    static func run() -> Int {
        var failures = 0
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
        print("Video vs music classification")
        failures += runClassificationCases()
        return failures
    }
}
