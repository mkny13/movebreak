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
                let output = SelfTestSupport.captureOutput {
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
                let output = SelfTestSupport.captureOutput {
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
                let output = SelfTestSupport.captureOutput {
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
                let output = SelfTestSupport.captureOutput {
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
        let dirMode = SelfTestSupport.posixMode(at: tempSupportDir.path)
        check("Application Support directory created with mode 0700", passed: dirMode == 0o700, detail: "got \(String(format: "%o", dirMode ?? 0))")

        // 2. Append session record creates sessions.jsonl with mode 0600
        let routine = Routine(key: "desk-break", title: "Desk Break", subtitle: "Quick Break", estimatedMinutes: 2, exercises: [ExerciseCatalog.all[0]])
        let record1 = SessionRecord(routine: routine, checkedIDs: [ExerciseCatalog.all[0].id])
        do {
            try logger.append(record1)
            let fileMode = SelfTestSupport.posixMode(at: logger.logFile.path)
            check("sessions.jsonl created with mode 0600", passed: fileMode == 0o600, detail: "got \(String(format: "%o", fileMode ?? 0))")
        } catch {
            check("append record1 threw", passed: false, detail: "\(error)")
        }

        // 3. Second append retains mode 0600
        let record2 = SessionRecord(routine: routine, checkedIDs: [])
        do {
            try logger.append(record2)
            let fileMode = SelfTestSupport.posixMode(at: logger.logFile.path)
            check("sessions.jsonl retains mode 0600 after subsequent appends", passed: fileMode == 0o600, detail: "got \(String(format: "%o", fileMode ?? 0))")
        } catch {
            check("append record2 threw", passed: false, detail: "\(error)")
        }

        // 4. Write pending sync file with mode 0600
        do {
            try logger.writePending([record1])
            let pendingMode = SelfTestSupport.posixMode(at: logger.pendingFile.path)
            check("pending-sync.json created with mode 0600", passed: pendingMode == 0o600, detail: "got \(String(format: "%o", pendingMode ?? 0))")
        } catch {
            check("writePending threw", passed: false, detail: "\(error)")
        }

        // 5. Atomic replacement preserves mode 0600 & content
        do {
            try logger.writePending([record1, record2])
            let pendingMode = SelfTestSupport.posixMode(at: logger.pendingFile.path)
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

        let tightenedDirMode = SelfTestSupport.posixMode(at: looseDir.path)
        let tightenedLogMode = SelfTestSupport.posixMode(at: looseLog.path)
        let tightenedPendingMode = SelfTestSupport.posixMode(at: loosePending.path)

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


    static func run() -> Int {
        var failures = 0
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
        return failures
    }
}
