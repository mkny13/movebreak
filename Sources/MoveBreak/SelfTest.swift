import Darwin
import Foundation

/// Dependency-free coordinator for the focused self-test suites.
///
/// Run with:  ./build/MoveBreak --self-test
enum SelfTest {
    private static let suites: [SelfTestSuite] = [
        SelfTestSuite(id: .detection, run: DetectionSelfTests.run),
        SelfTestSuite(id: .security, run: SecuritySelfTests.run),
        SelfTestSuite(id: .persistence, run: PersistenceSelfTests.run),
        SelfTestSuite(id: .update, run: UpdateSelfTests.run),
    ]

    static func run() -> Never {
        let runStarted = ProcessInfo.processInfo.systemUptime
        print("MoveBreak — self-test")
        print(String(repeating: "─", count: 78))

        let registeredIDs = suites.map(\.id)
        let expectedIDs = SelfTestSuiteID.allCases
        guard registeredIDs.count == expectedIDs.count,
              Set(registeredIDs) == Set(expectedIDs) else {
            print("✗ FAIL  self-test suite manifest is incomplete or contains duplicates")
            exit(1)
        }

        var failures = 0
        var cases = 0
        for (index, suite) in suites.enumerated() {
            if index > 0 { print("") }
            let casesBefore = SelfTestReporter.caseCountSnapshot()
            let suiteStarted = ProcessInfo.processInfo.systemUptime
            let suiteFailures = suite.run()
            let suiteElapsed = ProcessInfo.processInfo.systemUptime - suiteStarted
            let suiteCases = SelfTestReporter.caseCountSnapshot() - casesBefore
            failures += suiteFailures
            cases += suiteCases
            print("")
            print(
                "SUMMARY suite=\(suite.id.rawValue) cases=\(suiteCases) "
                    + "failures=\(suiteFailures) elapsed=\(formatDuration(suiteElapsed))"
            )
        }

        let runElapsed = ProcessInfo.processInfo.systemUptime - runStarted
        print(String(repeating: "─", count: 78))
        print(
            "SUMMARY total suites=\(suites.count) cases=\(cases) "
                + "failures=\(failures) elapsed=\(formatDuration(runElapsed))"
        )
        if failures == 0 {
            print("All cases passed.")
            exit(0)
        } else {
            print("\(failures) case(s) FAILED.")
            exit(1)
        }
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3fs", duration)
    }
}
