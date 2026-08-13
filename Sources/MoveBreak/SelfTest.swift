import Foundation

/// Exercises the video-vs-music rules directly, with no browser and no Automation grant.
///
/// These are the cases that decide whether the app interrupts you mid-song, so they're
/// worth being able to check on demand:  swift ... --self-test
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
            print("      expected \(testCase.expected ?? "no match"), got \(actual ?? "no match")")
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

    static func run() -> Never {
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
        print("MoveBreak — self-test")
        print(String(repeating: "─", count: 78))
        print("Bundle identity (helper process → owning app)")
        failures += runIdentityCases()
        print("")
        print("Exercise catalog + default routines")
        failures += runCatalogCases()
        print("")
        print("Video vs music classification")

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
