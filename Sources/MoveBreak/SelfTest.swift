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
        for (index, suite) in suites.enumerated() {
            if index > 0 { print("") }
            failures += suite.run()
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
