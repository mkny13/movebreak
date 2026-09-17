import AppKit
import Foundation

/// One-shot check of what the browsers currently have open and how it would classify.
///
/// Separate from `--diagnose` because the tab query does not depend on audio: this lets
/// the AppleScript path, the Automation grant, and the URL rules be tested without
/// anything playing.
///
/// Prints hosts rather than full URLs by default — it is reading your actual browsing.
/// Pass `--verbose` for full URLs.
enum TabProbe {

    static func run(verbose: Bool) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)

        let inspector = BrowserTabInspector()
        let running = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        let candidates = Preferences.browsers.filter { running.contains($0) }.sorted()

        print("MoveBreak — browser tab probe")
        print(String(repeating: "─", count: 78))

        guard !candidates.isEmpty else {
            print("No supported browser is running.")
            print("Supported: \(Preferences.browsers.sorted().joined(separator: ", "))")
            exit(0)
        }

        var sawError = false

        for bundleID in candidates {
            let inspection = inspector.inspectFresh(bundleID: bundleID)
            print("")
            print("\(bundleID)")

            if let error = inspection.scriptError {
                sawError = true
                print("   ⚠︎  \(error)")
                if error.contains("-1743") {
                    print("      Grant it in System Settings → Privacy & Security →")
                    print("      Automation → (this app) → Google Chrome.")
                }
            }

            print("   active tab : \(display(inspection.activeTabURL, verbose: verbose))")

            if inspection.allTabURLs.isEmpty {
                print("   window tabs: (not scanned — the active tab settled it)")
            } else {
                print("   window tabs: \(inspection.allTabURLs.count) window-active tabs")
                let shown = inspection.allTabURLs.prefix(verbose ? 100 : 12)
                for url in shown {
                    let tag = classifyTag(url)
                    print("                \(tag) \(display(url, verbose: verbose))")
                }
                if inspection.allTabURLs.count > shown.count {
                    print("                … \(inspection.allTabURLs.count - shown.count) more")
                }
            }

            print("   verdict    : \(describe(inspection.verdict))")
            print("   because    : \(inspection.reason)")
            print("   would prompt: \(inspection.verdict.isActionable ? "YES — if audio were playing" : "no")")
        }

        print("")
        print(String(repeating: "─", count: 78))
        print("Note: a verdict of VIDEO only prompts when that browser is actually")
        print("playing audio. This probe ignores audio state on purpose.")
        exit(sawError ? 1 : 0)
    }

    private static func classifyTag(_ url: String) -> String {
        if BrowserTabInspector.matches(url, Preferences.musicPatterns) { return "[music]" }
        if BrowserTabInspector.matches(url, Preferences.videoPatterns) { return "[video]" }
        return "[     ]"
    }

    private static func display(_ url: String?, verbose: Bool) -> String {
        URLDisplay.sanitize(url, verbose: verbose)
    }

    private static func describe(_ verdict: TabVerdict) -> String {
        switch verdict {
        case .meeting: return "MEETING"
        case .video:   return "VIDEO"
        case .music:   return "MUSIC (ignored)"
        case .unknown: return "UNKNOWN (ignored)"
        }
    }
}
