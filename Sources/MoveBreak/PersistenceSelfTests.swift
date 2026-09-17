import Darwin
import Foundation

enum PersistenceSelfTests {
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

    // MARK: - Keychain Typed Error Handling Cases

    private static func runKeychainCases() -> Int {
        let reporter = SelfTestReporter()

        let mockBackend = MockKeychainBackend()
        Keychain.withBackend(mockBackend) {
            // Set and get
            do {
                try Keychain.set("initial_val", forAccount: "acct1")
                let val = try Keychain.get(forAccount: "acct1")
                reporter.check("Keychain stores and retrieves value", passed: val == "initial_val")
            } catch {
                reporter.check("Keychain store/retrieve threw", passed: false, detail: "\(error)")
            }

            // Update existing
            do {
                try Keychain.set("updated_val", forAccount: "acct1")
                let val = try Keychain.get(forAccount: "acct1")
                reporter.check("Keychain updates existing value", passed: val == "updated_val")
            } catch {
                reporter.check("Keychain update threw", passed: false, detail: "\(error)")
            }

            // Non-existent item
            do {
                let val = try Keychain.get(forAccount: "nonexistent")
                reporter.check("Keychain returns nil for missing item", passed: val == nil)
            } catch {
                reporter.check("Keychain read of missing item threw", passed: false, detail: "\(error)")
            }

            // Delete item
            do {
                try Keychain.delete(forAccount: "acct1")
                let val = try Keychain.get(forAccount: "acct1")
                reporter.check("Keychain deletes item successfully", passed: val == nil)
            } catch {
                reporter.check("Keychain delete threw", passed: false, detail: "\(error)")
            }

            // Add error simulation
            mockBackend.simulatedAddError = .addFailed(status: errSecAuthFailed)
            var addFailedThrew = false
            do {
                try Keychain.set("new_val", forAccount: "acct2")
            } catch let err as KeychainError {
                if case .addFailed = err { addFailedThrew = true }
            } catch {}
            reporter.check("Keychain.set surfaces addFailed error", passed: addFailedThrew)
            mockBackend.simulatedAddError = nil

            // Read error simulation
            mockBackend.simulatedReadError = .readFailed(status: errSecItemNotFound)
            var readFailedThrew = false
            do {
                _ = try Keychain.get(forAccount: "acct2")
            } catch let err as KeychainError {
                if case .readFailed = err { readFailedThrew = true }
            } catch {}
            reporter.check("Keychain.get surfaces readFailed error", passed: readFailedThrew)
            mockBackend.simulatedReadError = nil
        }

        return reporter.failureCount
    }

    // MARK: - Notion Setup Failure Propagation Cases

    private static func runNotionSetupCases() -> Int {
        let reporter = SelfTestReporter()

        func capture(_ block: () -> Void) -> (stdout: String, stderr: String)? {
            do {
                return try SelfTestSupport.captureOutput(block: block)
            } catch {
                reporter.check("standard-stream capture infrastructure succeeds", false, detail: "\(error)")
                return nil
            }
        }

        let sentinelToken = "SENTINEL_NOTION_SECRET_987654321"
        let sentinelDbID = "test_database_id_abc"

        let suiteName = "com.mike.movebreak.tests.setup.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suiteName) else {
            reporter.check("UserDefaults test suite creation", passed: false)
            return 1
        }
        reporter.check("Notion setup defaults domain starts absent", testDefaults.persistentDomain(forName: suiteName) == nil)

        Preferences.withDefaults(testDefaults) {
            // Case 1: Keychain failure prevents partial setup & does not leak token
            let mockFailingKeychain = MockKeychainBackend()
            mockFailingKeychain.simulatedAddError = .addFailed(status: -1)

            Keychain.withBackend(mockFailingKeychain) {
                var exitCode: Int32 = -1
                let output = capture {
                    exitCode = NotionSetup.execute(
                        secretReader: { _ in sentinelToken },
                        databaseIDReader: { sentinelDbID }
                    )
                }

                reporter.check("NotionSetup returns exit code 1 on Keychain failure", passed: exitCode == 1)
                reporter.check("Database ID is NOT persisted on Keychain failure", passed: Preferences.notionDatabaseID == nil)
                reporter.check("Sentinel token absent from stdout on Keychain failure", passed: output?.stdout.contains(sentinelToken) == false)
                reporter.check("Sentinel token absent from stderr on Keychain failure", passed: output?.stderr.contains(sentinelToken) == false)
                reporter.check("Error message reported to stderr on failure", passed: output?.stderr.contains("error: failed to store token in Keychain") == true)
                reporter.check("Success message NOT printed on failure", passed: output?.stdout.contains("Saved. Completed routines will now log to Notion.") == false)
            }

            // Case 2: Empty token fails early without touching Keychain
            let mockKeychainUnused = MockKeychainBackend()
            Keychain.withBackend(mockKeychainUnused) {
                var exitCode: Int32 = -1
                let output = capture {
                    exitCode = NotionSetup.execute(
                        secretReader: { _ in "   \n" },
                        databaseIDReader: { sentinelDbID }
                    )
                }

                reporter.check("NotionSetup fails on empty token", passed: exitCode == 1)
                reporter.check("Empty token error reported to stderr", passed: output?.stderr.contains("error: no token entered") == true)
                reporter.check("Keychain untouched on empty token", passed: mockKeychainUnused.storage.isEmpty)
                reporter.check("Database ID not set on empty token", passed: Preferences.notionDatabaseID == nil)
            }

            // Case 3: Empty database ID fails without persisting
            Keychain.withBackend(mockKeychainUnused) {
                var exitCode: Int32 = -1
                let output = capture {
                    exitCode = NotionSetup.execute(
                        secretReader: { _ in sentinelToken },
                        databaseIDReader: { "   " }
                    )
                }

                reporter.check("NotionSetup fails on empty database ID", passed: exitCode == 1)
                reporter.check("Empty database ID error reported to stderr", passed: output?.stderr.contains("error: no database ID entered") == true)
                reporter.check("Database ID not set on empty database ID", passed: Preferences.notionDatabaseID == nil)
            }

            // Case 4: Successful setup stores token and database ID without leaking token to output
            let mockSuccessKeychain = MockKeychainBackend()
            Keychain.withBackend(mockSuccessKeychain) {
                var exitCode: Int32 = -1
                let output = capture {
                    exitCode = NotionSetup.execute(
                        secretReader: { _ in sentinelToken },
                        databaseIDReader: { sentinelDbID }
                    )
                }

                reporter.check("NotionSetup succeeds with valid inputs", passed: exitCode == 0)
                reporter.check("Database ID persisted on success", passed: Preferences.notionDatabaseID == sentinelDbID)
                do {
                    reporter.check(
                        "Sentinel token stored in Keychain",
                        passed: try Keychain.get(forAccount: NotionClient.tokenAccount) == sentinelToken
                    )
                } catch {
                    reporter.check("Sentinel token stored in Keychain", false, detail: "\(error)")
                }
                reporter.check("Sentinel token absent from stdout on success", passed: output?.stdout.contains(sentinelToken) == false)
                reporter.check("Sentinel token absent from stderr on success", passed: output?.stderr.contains(sentinelToken) == false)
                reporter.check("Success message printed on completion", passed: output?.stdout.contains("Saved. Completed routines will now log to Notion.") == true)
            }
        }

        testDefaults.removePersistentDomain(forName: suiteName)
        reporter.check(
            "Notion setup defaults domain is removed",
            testDefaults.persistentDomain(forName: suiteName) == nil
        )

        return reporter.failureCount
    }

    // MARK: - Harness Isolation and Failure-Path Regression Cases

    private static func runFixtureIsolationCases() -> Int {
        let reporter = SelfTestReporter()
        let baselineDefaults = Preferences.defaults
        let baselineKeychain = Keychain.backend
        let suiteName = "com.mike.movebreak.tests.isolation.\(UUID().uuidString)"

        guard let isolatedDefaults = UserDefaults(suiteName: suiteName) else {
            reporter.check("fixture-isolation UserDefaults suite is created", false)
            return reporter.failureCount
        }
        reporter.check("fixture-isolation defaults domain starts absent", isolatedDefaults.persistentDomain(forName: suiteName) == nil)

        Preferences.withDefaults(isolatedDefaults) {
            isolatedDefaults.set("success", forKey: "fixtureMarker")
        }
        reporter.check("UserDefaults override restores after success", Preferences.defaults === baselineDefaults)

        var defaultsFailureObserved = false
        do {
            try Preferences.withDefaults(isolatedDefaults) {
                throw NSError(domain: "SelfTestExpectedFailure", code: 1)
            }
        } catch {
            defaultsFailureObserved = true
        }
        reporter.check(
            "UserDefaults override restores after early failure",
            defaultsFailureObserved && Preferences.defaults === baselineDefaults
        )

        let mockBackend = MockKeychainBackend()
        Keychain.withBackend(mockBackend) {}
        reporter.check("mock Keychain override restores after success", Keychain.backend === baselineKeychain)

        var keychainFailureObserved = false
        do {
            try Keychain.withBackend(mockBackend) {
                throw NSError(domain: "SelfTestExpectedFailure", code: 2)
            }
        } catch {
            keychainFailureObserved = true
        }
        reporter.check(
            "mock Keychain override restores after early failure",
            keychainFailureObserved && Keychain.backend === baselineKeychain
        )

        isolatedDefaults.removePersistentDomain(forName: suiteName)
        reporter.check(
            "fixture-isolation defaults domain is removed",
            isolatedDefaults.persistentDomain(forName: suiteName) == nil
        )

        let setupFailureParent = SelfTestTemporaryDirectory(prefix: "movebreak-setup-failure-parent")
        do {
            try setupFailureParent.create()
            let blocker = setupFailureParent.url.appendingPathComponent("regular-file")
            try Data("not a directory".utf8).write(to: blocker)
            let failingFixture = SelfTestTemporaryDirectory(prefix: "child", baseURL: blocker)
            var setupFailureObserved = false
            do {
                try failingFixture.create()
            } catch {
                setupFailureObserved = true
            }
            reporter.check(
                "temporary fixture creation failure is observable",
                setupFailureObserved && !FileManager.default.fileExists(atPath: failingFixture.url.path)
            )
            try failingFixture.cleanup()
            try setupFailureParent.cleanup()
            reporter.check(
                "fixture creation failure leaves no temporary paths",
                !FileManager.default.fileExists(atPath: setupFailureParent.url.path)
            )
        } catch {
            reporter.check("temporary fixture creation failure regression setup succeeds", false, detail: "\(error)")
            do {
                try setupFailureParent.cleanup()
            } catch {
                reporter.check("fixture creation failure regression cleanup succeeds", false, detail: "\(error)")
            }
        }

        let permissionFixture = SelfTestTemporaryDirectory(prefix: "movebreak-cleanup-permissions")
        do {
            try permissionFixture.create(permissions: 0o700)
            guard chmod(permissionFixture.url.path, 0o000) == 0 else {
                throw SelfTestInfrastructureError.posix(operation: "lock cleanup fixture", code: errno)
            }
            try permissionFixture.cleanup()
            try permissionFixture.cleanup()
            reporter.check(
                "temporary cleanup restores permissions, removes the path, and is idempotent",
                !FileManager.default.fileExists(atPath: permissionFixture.url.path)
            )
        } catch {
            reporter.check("temporary cleanup restores permissions and removes the path", false, detail: "\(error)")
        }

        let cleanupFailureFixture = SelfTestTemporaryDirectory(prefix: "movebreak-cleanup-failure")
        do {
            try cleanupFailureFixture.create()
            var cleanupFailureObserved = false
            do {
                try cleanupFailureFixture.cleanup { _ in
                    throw NSError(domain: "SelfTestExpectedCleanupFailure", code: 1)
                }
            } catch {
                cleanupFailureObserved = true
            }
            reporter.check(
                "temporary cleanup failure is observable and retains the fixture for retry",
                cleanupFailureObserved && FileManager.default.fileExists(atPath: cleanupFailureFixture.url.path)
            )
            try cleanupFailureFixture.cleanup()
            reporter.check(
                "temporary cleanup retry removes the fixture",
                !FileManager.default.fileExists(atPath: cleanupFailureFixture.url.path)
            )
        } catch {
            reporter.check("temporary cleanup failure regression fixture succeeds", false, detail: "\(error)")
        }

        let descriptorsBeforeFailure = SelfTestSupport.openFileDescriptorCount()
        var captureBodyRan = false
        var captureFailureObserved = false
        do {
            _ = try SelfTestSupport.captureOutput(pipeFactory: { _ in
                errno = EMFILE
                return -1
            }) {
                captureBodyRan = true
            }
        } catch {
            captureFailureObserved = true
        }
        let descriptorsAfterFailure = SelfTestSupport.openFileDescriptorCount()
        reporter.check(
            "output-capture setup failure is observable and leak-free",
            captureFailureObserved && !captureBodyRan && descriptorsAfterFailure == descriptorsBeforeFailure,
            detail: "before=\(descriptorsBeforeFailure), after=\(descriptorsAfterFailure)"
        )

        let descriptorsBeforeCaptures = SelfTestSupport.openFileDescriptorCount()
        var repeatedCapturesPassed = true
        for index in 0..<20 {
            do {
                let output = try SelfTestSupport.captureOutput {
                    print("capture-\(index)")
                    FileHandle.standardError.write(Data("error-\(index)\n".utf8))
                }
                repeatedCapturesPassed = repeatedCapturesPassed
                    && output.stdout == "capture-\(index)\n"
                    && output.stderr == "error-\(index)\n"
            } catch {
                repeatedCapturesPassed = false
            }
        }
        let descriptorsAfterCaptures = SelfTestSupport.openFileDescriptorCount()
        reporter.check(
            "repeated output captures restore streams and descriptor baseline",
            repeatedCapturesPassed && descriptorsAfterCaptures == descriptorsBeforeCaptures,
            detail: "before=\(descriptorsBeforeCaptures), after=\(descriptorsAfterCaptures)"
        )

        return reporter.failureCount
    }

    // MARK: - SessionLogger Directory & File Permission Cases

    private static func runSessionLoggerPermissionCases() -> Int {
        let reporter = SelfTestReporter()

        let tempSupportFixture = SelfTestTemporaryDirectory(prefix: "movebreak-perm")
        let tempSupportDir = tempSupportFixture.url

        let logger = SessionLogger(supportDir: tempSupportDir)

        // 1. Directory creation mode 0700
        let dirMode = SelfTestSupport.posixMode(at: tempSupportDir.path)
        reporter.check("Application Support directory created with mode 0700", passed: dirMode == 0o700, detail: "got \(String(format: "%o", dirMode ?? 0))")

        // 2. Append session record creates sessions.jsonl with mode 0600
        let routine = Routine(key: "desk-break", title: "Desk Break", subtitle: "Quick Break", estimatedMinutes: 2, exercises: [ExerciseCatalog.all[0]])
        let record1 = SessionRecord(routine: routine, checkedIDs: [ExerciseCatalog.all[0].id])
        do {
            try logger.append(record1)
            let fileMode = SelfTestSupport.posixMode(at: logger.logFile.path)
            reporter.check("sessions.jsonl created with mode 0600", passed: fileMode == 0o600, detail: "got \(String(format: "%o", fileMode ?? 0))")
        } catch {
            reporter.check("append record1 threw", passed: false, detail: "\(error)")
        }

        // 3. Second append retains mode 0600
        let record2 = SessionRecord(routine: routine, checkedIDs: [])
        do {
            try logger.append(record2)
            let fileMode = SelfTestSupport.posixMode(at: logger.logFile.path)
            reporter.check("sessions.jsonl retains mode 0600 after subsequent appends", passed: fileMode == 0o600, detail: "got \(String(format: "%o", fileMode ?? 0))")
        } catch {
            reporter.check("append record2 threw", passed: false, detail: "\(error)")
        }

        // 4. Write pending sync file with mode 0600
        do {
            try logger.writePending([record1])
            let pendingMode = SelfTestSupport.posixMode(at: logger.pendingFile.path)
            reporter.check("pending-sync.json created with mode 0600", passed: pendingMode == 0o600, detail: "got \(String(format: "%o", pendingMode ?? 0))")
        } catch {
            reporter.check("writePending threw", passed: false, detail: "\(error)")
        }

        // 5. Atomic replacement preserves mode 0600 & content
        do {
            try logger.writePending([record1, record2])
            let pendingMode = SelfTestSupport.posixMode(at: logger.pendingFile.path)
            reporter.check("pending-sync.json retains mode 0600 after atomic rewrite", passed: pendingMode == 0o600, detail: "got \(String(format: "%o", pendingMode ?? 0))")
            let readBack = try logger.readPending()
            reporter.check("readPending accurately decodes updated records", passed: readBack.count == 2)
        } catch {
            reporter.check("atomic writePending / readPending threw", passed: false, detail: "\(error)")
        }

        // 6. Startup tightening of loose permissions (0777 dir -> 0700, 0666/0644 files -> 0600)
        let looseFixture = SelfTestTemporaryDirectory(prefix: "movebreak-loose")
        let looseDir = looseFixture.url
        do {
            try looseFixture.create(permissions: 0o777)
        } catch {
            reporter.check("loose-permission fixture directory is created", false, detail: "\(error)")
        }

        let looseLog = looseDir.appendingPathComponent("sessions.jsonl")
        let loosePending = looseDir.appendingPathComponent("pending-sync.json")
        reporter.check(
            "loose sessions fixture is created",
            FileManager.default.createFile(atPath: looseLog.path, contents: Data("line\n".utf8), attributes: [.posixPermissions: 0o666])
        )
        reporter.check(
            "loose pending fixture is created",
            FileManager.default.createFile(atPath: loosePending.path, contents: Data("[]".utf8), attributes: [.posixPermissions: 0o644])
        )

        _ = SessionLogger(supportDir: looseDir)

        let tightenedDirMode = SelfTestSupport.posixMode(at: looseDir.path)
        let tightenedLogMode = SelfTestSupport.posixMode(at: looseLog.path)
        let tightenedPendingMode = SelfTestSupport.posixMode(at: loosePending.path)

        reporter.check("Startup tightens directory permissions to 0700", passed: tightenedDirMode == 0o700, detail: "got \(String(format: "%o", tightenedDirMode ?? 0))")
        reporter.check("Startup tightens sessions.jsonl to 0600", passed: tightenedLogMode == 0o600, detail: "got \(String(format: "%o", tightenedLogMode ?? 0))")
        reporter.check("Startup tightens pending-sync.json to 0600", passed: tightenedPendingMode == 0o600, detail: "got \(String(format: "%o", tightenedPendingMode ?? 0))")

        for (name, fixture) in [("loose-permission", looseFixture), ("session logger", tempSupportFixture)] {
            do {
                try fixture.cleanup()
                reporter.check("\(name) temporary directory is removed", true)
            } catch {
                reporter.check("\(name) temporary directory is removed", false, detail: "\(error)")
            }
        }

        return reporter.failureCount
    }

    // MARK: - Local Persistence Failure Observability Cases

    private static func runPersistenceFailureCases() -> Int {
        let reporter = SelfTestReporter()

        let testFixture = SelfTestTemporaryDirectory(prefix: "movebreak-ro")
        let testDir = testFixture.url
        do {
            try testFixture.create(permissions: 0o700)
        } catch {
            reporter.check("read-only persistence fixture is created", false, detail: "\(error)")
            return reporter.failureCount
        }

        let loggerQueue = DispatchQueue(label: "com.mike.movebreak.tests.persistence-failure")
        let testLogger = SessionLogger(supportDir: testDir, queue: loggerQueue)
        let sampleRoutine = Routine(key: "pt", title: "PT", subtitle: "Desk PT", estimatedMinutes: 2, exercises: [ExerciseCatalog.all[0]])
        let sampleRecord = SessionRecord(routine: sampleRoutine, checkedIDs: [ExerciseCatalog.all[0].id])

        // Revoke write permissions on the directory
        reporter.check("persistence fixture permissions become read-only", chmod(testDir.path, 0o500) == 0)

        var appendThrew = false
        do {
            try testLogger.append(sampleRecord)
        } catch {
            appendThrew = true
        }
        reporter.check("append throws SessionLoggerError on read-only directory", passed: appendThrew)

        var pendingThrew = false
        do {
            try testLogger.writePending([sampleRecord])
        } catch {
            pendingThrew = true
        }
        reporter.check("writePending throws SessionLoggerError on read-only directory", passed: pendingThrew)

        let callbackLock = NSLock()
        var callbackResults: [Result<SessionRecord, Error>] = []
        var operationDrained = false
        var lateCallbackCount = 0
        testLogger.logCompletion(record: sampleRecord) { result in
            callbackLock.withLock {
                if operationDrained { lateCallbackCount += 1 }
                callbackResults.append(result)
            }
        }

        let operationBarrier = DispatchSemaphore(value: 0)
        loggerQueue.async {
            callbackLock.withLock { operationDrained = true }
            operationBarrier.signal()
        }
        let operationDrainResult = operationBarrier.wait(timeout: .now() + 5)
        reporter.check(
            "logCompletion persistence operation drains",
            passed: operationDrainResult == .success,
            detail: "logger queue barrier timed out"
        )

        // A second barrier catches a callback that the operation queued behind the first
        // barrier, allowing late delivery to be distinguished from missing delivery.
        let callbackBarrier = DispatchSemaphore(value: 0)
        loggerQueue.async { callbackBarrier.signal() }
        let callbackDrainResult = callbackBarrier.wait(timeout: .now() + 5)
        reporter.check(
            "logCompletion callback work drains",
            passed: callbackDrainResult == .success,
            detail: "logger callback barrier timed out"
        )

        let callbackSnapshot = callbackLock.withLock {
            (results: callbackResults, lateCount: lateCallbackCount)
        }
        reporter.check(
            "logCompletion reports a callback before the operation drains",
            passed: !callbackSnapshot.results.isEmpty && callbackSnapshot.lateCount == 0,
            detail: callbackSnapshot.results.isEmpty
                ? "callback was missing"
                : "\(callbackSnapshot.lateCount) callback(s) arrived late"
        )
        reporter.check(
            "logCompletion reports exactly one callback",
            passed: callbackSnapshot.results.count == 1,
            detail: "observed \(callbackSnapshot.results.count) callbacks"
        )
        let callbackFailed: Bool
        if callbackSnapshot.results.count == 1,
           case .failure = callbackSnapshot.results[0] {
            callbackFailed = true
        } else {
            callbackFailed = false
        }
        reporter.check(
            "logCompletion reports failure rather than success on persistence error",
            passed: callbackFailed,
            detail: "expected one failure result"
        )

        reporter.check("persistence fixture permissions are restored", chmod(testDir.path, 0o700) == 0)
        do {
            try testFixture.cleanup()
            reporter.check("read-only persistence fixture is removed", true)
        } catch {
            reporter.check("read-only persistence fixture is removed", false, detail: "\(error)")
        }
        return reporter.failureCount
    }

    // MARK: - Session Record Compatibility Cases

    private static func runSessionCompatibilityCases() -> Int {
        let reporter = SelfTestReporter()

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
            reporter.check("sample JSON encoding", passed: false)
            return 1
        }

        do {
            let decoder = JSONDecoder()
            let record = try decoder.decode(SessionRecord.self, from: data)

            reporter.check("SessionRecord decodes legacy JSON id", passed: record.id == sampleUUID)
            reporter.check("SessionRecord decodes legacy JSON date", passed: record.date.timeIntervalSinceReferenceDate == 748051200.0)
            reporter.check("SessionRecord decodes legacy JSON routineKey", passed: record.routineKey == "desk-pt")
            reporter.check("SessionRecord decodes legacy JSON routineTitle", passed: record.routineTitle == "Desk PT")
            reporter.check("SessionRecord decodes legacy JSON completed exercises", passed: record.exercisesCompleted == ["Chin Tucks", "Shoulder Rolls"])
            reporter.check("SessionRecord decodes legacy JSON completedCount", passed: record.completedCount == 2)
            reporter.check("SessionRecord decodes legacy JSON totalCount", passed: record.totalCount == 2)
            reporter.check("SessionRecord decodes legacy JSON estimatedMinutes", passed: record.estimatedMinutes == 3)

            let encoder = JSONEncoder()
            let reencoded = try encoder.encode(record)
            let decodedAgain = try decoder.decode(SessionRecord.self, from: reencoded)
            reporter.check("SessionRecord round-trips identically", passed: decodedAgain.id == record.id && decodedAgain.completedCount == record.completedCount)
        } catch {
            reporter.check("SessionRecord decoding failed", passed: false, detail: "\(error)")
        }

        return reporter.failureCount
    }


    static func run() -> Int {
        var failures = 0
        print("Keychain typed error handling, access class & isolation")
        failures += runKeychainCases()
        print("")
        print("Notion setup failure propagation & credential boundaries")
        failures += runNotionSetupCases()
        print("")
        print("Self-test fixture isolation, failure reporting & resource cleanup")
        failures += runFixtureIsolationCases()
        print("")
        print("Local session directory (0700) & file permissions (0600)")
        failures += runSessionLoggerPermissionCases()
        print("")
        print("Local session persistence failure observability")
        failures += runPersistenceFailureCases()
        print("")
        print("Session record JSON schema compatibility")
        failures += runSessionCompatibilityCases()
        return failures
    }
}
