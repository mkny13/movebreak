import Foundation

/// Live view of what the detector sees, so detection can be validated against real
/// meetings and real tabs before any UI exists.
///
/// Run with:  swift run MoveBreak --diagnose
enum Diagnose {

    static func run() -> Never {
        guard AudioActivityMonitor.isSupported else {
            FileHandle.standardError.write(Data("""
            error: this macOS build does not expose kAudioHardwarePropertyProcessObjectList.
                   The per-process audio API requires macOS 14.4 or later.

            """.utf8))
            exit(1)
        }

        // Unbuffered: this is a live diagnostic, and when piped to `head`/`tee` or killed
        // with Ctrl-C, block buffering would swallow everything printed so far.
        setvbuf(stdout, nil, _IONBF, 0)

        let detector = SessionDetector()
        var lastSignature: String?

        print("MoveBreak — detection diagnostics")
        print("Polling every \(Preferences.pollInterval)s. Ctrl-C to stop.")
        print(String(repeating: "─", count: 78))

        while true {
            let result = detector.poll()
            let stamp = timestamp()

            // Redraw when anything observable changes — including which processes hold
            // streams, not just the verdict. A process appearing or dropping out is
            // exactly what you're trying to see while testing.
            let signature = self.signature(for: result)
            if signature != lastSignature {
                print("")
                print("[\(stamp)] STATE: \(result.state.label.uppercased())  —  \(result.reason)")
                printProcesses(result.activeProcesses)
                printInspections(result.inspections)
                lastSignature = signature
            } else {
                // Heartbeat so it's obvious the thing is alive and not wedged.
                FileHandle.standardOutput.write(Data(".".utf8))
            }

            Thread.sleep(forTimeInterval: Preferences.pollInterval)
        }
    }

    private static func signature(for result: Classification) -> String {
        let processes = result.activeProcesses
            .filter { $0.isRunningInput || $0.isRunningOutput }
            .map { "\($0.pid):\($0.bundleID ?? "-"):\($0.isRunningInput ? 1 : 0)\($0.isRunningOutput ? 1 : 0)" }
            .sorted()
            .joined(separator: ",")
        return "\(result.state.label)|\(result.reason)|\(processes)"
    }

    private static func printProcesses(_ processes: [AudioProcess]) {
        let active = processes.filter { $0.isRunningInput || $0.isRunningOutput }
        guard !active.isEmpty else {
            print("        (no process holds a live audio stream)")
            return
        }
        print("        \("PID".padded(7))\("BUNDLE ID".padded(38))IN   OUT  RESOLVES TO")
        for process in active.sorted(by: { ($0.bundleID ?? "") < ($1.bundleID ?? "") }) {
            let pid = String(process.pid).padded(7)
            let bundle = (process.bundleID ?? "‹none›").padded(38)
            let input = (process.isRunningInput ? "yes" : " · ").padded(5)
            let output = (process.isRunningOutput ? "yes" : " · ").padded(5)
            print("        \(pid)\(bundle)\(input)\(output)\(category(of: process.bundleID))")
        }
    }

    /// Shows which list a process resolved into. Makes an unrecognised app obvious at a
    /// glance — "not in any list" is the usual reason something isn't detected.
    private static func category(of bundleID: String?) -> String {
        guard let bundleID else { return "‹no bundle id — cannot classify›" }
        if let owner = BundleIdentity.owner(of: bundleID, in: Preferences.ignoredApps) {
            return "\(owner)  [ignored]"
        }
        if let owner = BundleIdentity.owner(of: bundleID, in: Preferences.browsers) {
            return "\(owner)  [browser → check tabs]"
        }
        if let owner = BundleIdentity.owner(of: bundleID, in: Preferences.meetingApps) {
            return "\(owner)  [meeting app]"
        }
        if let owner = BundleIdentity.owner(of: bundleID, in: Preferences.nativePlayers) {
            return "\(owner)  [native player]"
        }
        return "not in any list"
    }

    private static func printInspections(_ inspections: [TabInspection]) {
        for inspection in inspections {
            print("        ── tab inspection: \(inspection.bundleID)")
            if let error = inspection.scriptError {
                print("           ⚠︎ \(error)")
            }
            print("           active tab : \(truncate(inspection.activeTabURL ?? "‹none›"))")
            if !inspection.allTabURLs.isEmpty {
                print("           all tabs   : \(inspection.allTabURLs.count) open")
                for url in inspection.allTabURLs.prefix(8) {
                    print("                        \(truncate(url))")
                }
                if inspection.allTabURLs.count > 8 {
                    print("                        … \(inspection.allTabURLs.count - 8) more")
                }
            }
            print("           verdict    : \(describe(inspection.verdict)) — \(inspection.reason)")
        }
    }

    private static func describe(_ verdict: TabVerdict) -> String {
        switch verdict {
        case .meeting: return "MEETING"
        case .video:   return "VIDEO"
        case .music:   return "MUSIC (ignored)"
        case .unknown: return "UNKNOWN (ignored)"
        }
    }

    private static func truncate(_ string: String, limit: Int = 76) -> String {
        string.count <= limit ? string : String(string.prefix(limit - 1)) + "…"
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

private extension String {
    func padded(_ width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }
}
