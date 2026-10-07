import Darwin
import Foundation

enum PersistenceSelfTests {
    private final class ScriptedTransport: GroundworkTransport {
        struct Response {
            let status: Int?
            let data: Data?
            let headers: [String: String]
            let error: Error?
        }

        private let lock = NSLock()
        private var responses: [Response]
        private(set) var requests: [URLRequest] = []

        init(_ responses: [Response]) { self.responses = responses }

        @discardableResult
        func send(
            _ request: URLRequest,
            completion: @escaping (Data?, URLResponse?, Error?) -> Void
        ) -> GroundworkRequestCancellation {
            let response: Response = lock.withLock {
                requests.append(request)
                return responses.isEmpty
                    ? Response(status: nil, data: nil, headers: [:], error: URLError(.notConnectedToInternet))
                    : responses.removeFirst()
            }
            DispatchQueue.global().async {
                let http = response.status.flatMap {
                    HTTPURLResponse(url: request.url!, statusCode: $0, httpVersion: nil, headerFields: response.headers)
                }
                completion(response.data, http, response.error)
            }
            return NoopCancellation()
        }

        var requestCount: Int { lock.withLock { requests.count } }
    }

    private struct NoopCancellation: GroundworkRequestCancellation { func cancel() {} }

    private static let originA = GroundworkOrigin(url: URL(string: "https://groundwork-a.example")!)!
    private static let originB = GroundworkOrigin(url: URL(string: "https://groundwork-b.example")!)!

    private static func completion(
        id: UUID = UUID(),
        finishedAt: Date = Date(timeIntervalSince1970: 1_800_000_100)
    ) -> RoutineCompletion {
        let routine = Routine(
            key: "local-test",
            title: "Local Test",
            subtitle: "Persistence fixture",
            estimatedMinutes: 2,
            exercises: [ExerciseCatalog.all[0]]
        )
        return RoutineSessionTracker(
            routine: routine,
            clientSessionID: id,
            startedAt: finishedAt.addingTimeInterval(-120)
        ).finish(
            checkedIDs: [routine.exercises[0].id],
            actualDoses: [:],
            warningReasons: [:],
            finishedAt: finishedAt
        )!
    }

    private static func receipt(
        for request: GroundworkCompletionRequest,
        duplicate: Bool = false
    ) -> Data {
        try! GroundworkCoding.encoder().encode(GroundworkCompletionReceipt(
            schemaVersion: GroundworkSchema.version,
            clientSessionID: request.clientSessionID,
            acceptedAt: request.finishedAt.addingTimeInterval(1),
            duplicate: duplicate
        ))
    }

    private static func clientFactory(
        transport: ScriptedTransport,
        observedOrigins: LockedBox<[GroundworkOrigin]>? = nil
    ) -> GroundworkOutbox.ClientFactory {
        { origin in
            observedOrigins?.withValue { $0.append(origin) }
            return try GroundworkClient(baseURL: origin.url!, bearer: "example-bearer", transport: transport)
        }
    }

    private static func eventually(
        timeout: TimeInterval = 3,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private static func load(_ outbox: GroundworkOutbox) -> GroundworkOutboxDocument? {
        try? outbox.readDocument()
    }

    private static func runSessionRecordCases() -> Int {
        let reporter = SelfTestReporter()
        let legacyID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
        let legacyJSON = """
        {"id":"\(legacyID.uuidString)","date":748051200,"routineKey":"desk-pt",\
        "routineTitle":"Desk PT","exercisesCompleted":["Chin Tucks"],\
        "completedCount":1,"totalCount":2,"estimatedMinutes":3}
        """
        do {
            let legacy = try JSONDecoder().decode(SessionRecord.self, from: Data(legacyJSON.utf8))
            reporter.check("Legacy JSONL remains readable", legacy.id == legacyID
                && legacy.groundworkCompletion == nil && legacy.groundworkDestination == nil)
            let structured = SessionRecord(completion: completion(id: legacyID), destination: originA)
            reporter.check("Structured history uses the stable HUD UUID", structured.id == legacyID)
            reporter.check("Structured history retains the completion snapshot and origin",
                structured.groundworkCompletion?.clientSessionID == legacyID
                    && structured.groundworkDestination == originA)
            let roundTrip = try JSONDecoder().decode(
                SessionRecord.self,
                from: JSONEncoder().encode(structured)
            )
            reporter.check("Structured history round-trips", roundTrip.id == structured.id
                && roundTrip.groundworkCompletion == structured.groundworkCompletion)
        } catch {
            reporter.check("Session record compatibility cases complete", false, detail: "\(error)")
        }
        return reporter.failureCount
    }

    private static func runDurabilityAndRecoveryCases() -> Int {
        let reporter = SelfTestReporter()
        let fixture = SelfTestTemporaryDirectory(prefix: "movebreak-outbox-recovery")
        let value = completion()
        let record = SessionRecord(completion: value, destination: originA)
        let transport = ScriptedTransport([
            .init(status: 200, data: receipt(for: value.request), headers: ["Content-Type": "application/json"], error: nil),
        ])
        let outbox = GroundworkOutbox(
            supportDir: fixture.url,
            currentOrigin: { originA },
            clientFactory: clientFactory(transport: transport)
        )
        let logger = SessionLogger(
            supportDir: fixture.url,
            outbox: outbox,
            currentOrigin: { originA }
        )

        do {
            // Simulate a crash after the first persistence boundary.
            try logger.append(record)
            reporter.check("History is durable before outbox recovery",
                try logger.readHistory().map(\.id) == [record.id])
            logger.recoverAndRetry()
            reporter.check("Relaunch recovery delivers history-only completion", eventually {
                load(outbox)?.delivered.map(\.clientSessionID) == [record.id]
            })
            reporter.check("Recovery sends exactly once", transport.requestCount == 1)

            // A second recovery consults the receipt ledger and must not recreate the item.
            logger.recoverAndRetry()
            Thread.sleep(forTimeInterval: 0.05)
            reporter.check("Receipt ledger prevents re-enqueue after relaunch", transport.requestCount == 1
                && load(outbox)?.items.isEmpty == true)
            reporter.check("Outbox is owner-readable only",
                SelfTestSupport.posixMode(at: outbox.fileURL.path) == 0o600)
            _ = chmod(outbox.fileURL.path, 0o644)
            _ = chmod(fixture.url.path, 0o755)
            _ = try outbox.readDocument()
            reporter.check("Existing outbox and receipt ledger tighten before read",
                SelfTestSupport.posixMode(at: outbox.fileURL.path) == 0o600
                && SelfTestSupport.posixMode(at: fixture.url.path) == 0o700)
        } catch {
            reporter.check("Durability and recovery cases complete", false, detail: "\(error)")
        }

        do { try fixture.cleanup() }
        catch { reporter.check("Recovery fixture cleanup", false, detail: "\(error)") }
        return reporter.failureCount
    }

    private static func runRetryAndReceiptCases() -> Int {
        let reporter = SelfTestReporter()
        let fixture = SelfTestTemporaryDirectory(prefix: "movebreak-outbox-retry")
        let value = completion()
        let record = SessionRecord(completion: value, destination: originA)
        let transport = ScriptedTransport([
            // Models a response lost after the server committed.
            .init(status: nil, data: nil, headers: [:], error: URLError(.networkConnectionLost)),
            .init(status: 200, data: receipt(for: value.request, duplicate: true), headers: ["Content-Type": "application/json"], error: nil),
        ])
        let outbox = GroundworkOutbox(
            supportDir: fixture.url,
            jitter: { 1 },
            currentOrigin: { originA },
            clientFactory: clientFactory(transport: transport)
        )
        let callback = DispatchSemaphore(value: 0)
        outbox.enqueue(record) { _ in callback.signal() }
        reporter.check("Completion waits for durable outbox write", callback.wait(timeout: .now() + 2) == .success
            && FileManager.default.fileExists(atPath: outbox.fileURL.path))
        reporter.check("Network loss remains queued with bounded retry state", eventually {
            load(outbox)?.items.first?.state == .retryScheduled
                && load(outbox)?.items.first?.attemptCount == 1
        })
        outbox.retryFailed()
        reporter.check("Duplicate receipt after lost response is accepted", eventually {
            load(outbox)?.items.isEmpty == true && load(outbox)?.delivered.count == 1
        })
        reporter.check("Lost-response recovery used the same idempotency UUID", transport.requestCount == 2)

        do { try fixture.cleanup() }
        catch { reporter.check("Retry fixture cleanup", false, detail: "\(error)") }
        return reporter.failureCount
    }

    private static func runFailureClassificationCases() -> Int {
        let reporter = SelfTestReporter()
        let cases: [(String, Int, GroundworkOutboxItemState)] = [
            ("401 pauses for reconfiguration", 401, .authenticationPaused),
            ("400 remains visible", 400, .permanentFailure),
            ("409 conflict remains visible", 409, .permanentFailure),
            ("429 schedules retry", 429, .retryScheduled),
            ("5xx schedules retry", 503, .retryScheduled),
        ]
        for (name, status, expected) in cases {
            let fixture = SelfTestTemporaryDirectory(prefix: "movebreak-outbox-http")
            let value = completion()
            let transport = ScriptedTransport([
                .init(status: status, data: Data(), headers: status == 429 ? ["Retry-After": "60"] : [:], error: nil),
            ])
            let outbox = GroundworkOutbox(
                supportDir: fixture.url,
                currentOrigin: { originA },
                clientFactory: clientFactory(transport: transport)
            )
            outbox.enqueue(SessionRecord(completion: value, destination: originA)) { _ in }
            reporter.check(name, eventually { load(outbox)?.items.first?.state == expected })
            if status == 429 {
                reporter.check("Retry-After is respected", (load(outbox)?.items.first?.nextAttemptAt?
                    .timeIntervalSinceNow ?? 0) > 50)
            }
            try? fixture.cleanup()
        }
        return reporter.failureCount
    }

    private static func runDestinationAndLegacyIsolationCases() -> Int {
        let reporter = SelfTestReporter()
        let fixture = SelfTestTemporaryDirectory(prefix: "movebreak-outbox-origin")
        try? fixture.create(permissions: 0o700)
        let valueA = completion()
        let valueUnbound = completion()
        let observed = LockedBox<[GroundworkOrigin]>([])
        let transport = ScriptedTransport([
            .init(status: 200, data: receipt(for: valueA.request), headers: ["Content-Type": "application/json"], error: nil),
            .init(status: 200, data: receipt(for: valueUnbound.request), headers: ["Content-Type": "application/json"], error: nil),
        ])
        let outbox = GroundworkOutbox(
            supportDir: fixture.url,
            currentOrigin: { originB },
            clientFactory: clientFactory(transport: transport, observedOrigins: observed)
        )
        let legacyPending = fixture.url.appendingPathComponent("pending-sync.json")
        let legacyBytes = Data("LEGACY_NOTION_QUEUE_MUST_STAY_UNTOUCHED".utf8)
        _ = FileManager.default.createFile(atPath: legacyPending.path, contents: legacyBytes)

        outbox.enqueue(SessionRecord(completion: valueUnbound, destination: nil)) { _ in }
        Thread.sleep(forTimeInterval: 0.05)
        reporter.check("Unconfigured completion stays visible without network", transport.requestCount == 0
            && outbox.status.failed == 1)
        outbox.enqueue(SessionRecord(completion: valueA, destination: originA)) { _ in }
        reporter.check("Unconfigured work does not block a later bound destination", eventually {
            observed.value.first == originA && load(outbox)?.delivered.count == 1
        })
        reporter.check("Destination change does not reassign queued health data",
            observed.value.first == originA)
        outbox.retryFailed()
        reporter.check("Explicit retry binds an unconfigured record to current origin", eventually {
            observed.value.last == originB && load(outbox)?.delivered.count == 2
        })
        reporter.check("Legacy Notion queue remains byte-for-byte untouched",
            (try? Data(contentsOf: legacyPending)) == legacyBytes)

        do { try fixture.cleanup() }
        catch { reporter.check("Origin fixture cleanup", false, detail: "\(error)") }
        return reporter.failureCount
    }

    private static func runConcurrentAndCorruptionCases() -> Int {
        let reporter = SelfTestReporter()
        let fixture = SelfTestTemporaryDirectory(prefix: "movebreak-outbox-concurrent")
        let value = completion()
        let transport = ScriptedTransport([
            .init(status: 200, data: receipt(for: value.request), headers: ["Content-Type": "application/json"], error: nil),
        ])
        let outbox = GroundworkOutbox(
            supportDir: fixture.url,
            currentOrigin: { originA },
            clientFactory: clientFactory(transport: transport)
        )
        let record = SessionRecord(completion: value, destination: originA)
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async { outbox.enqueue(record) { _ in group.leave() } }
        }
        reporter.check("Concurrent completion calls finish", group.wait(timeout: .now() + 3) == .success)
        reporter.check("Concurrent completion is delivered once", eventually {
            transport.requestCount == 1 && load(outbox)?.delivered.count == 1
        })
        try? fixture.cleanup()

        let corruptFixture = SelfTestTemporaryDirectory(prefix: "movebreak-outbox-corrupt")
        try? corruptFixture.create(permissions: 0o700)
        let corruptOutbox = GroundworkOutbox(supportDir: corruptFixture.url, currentOrigin: { originA })
        let corruptBytes = Data("{PRIVATE_CORRUPT_HEALTH_BYTES".utf8)
        _ = FileManager.default.createFile(atPath: corruptOutbox.fileURL.path, contents: corruptBytes)
        let callback = LockedBox<Result<Void, Error>?>(nil)
        corruptOutbox.enqueue(record) { callback.value = $0 }
        reporter.check("Malformed outbox blocks mutation and reports failure", eventually {
            if case .failure? = callback.value { return true }
            return false
        })
        reporter.check("Malformed outbox is preserved byte-for-byte",
            (try? Data(contentsOf: corruptOutbox.fileURL)) == corruptBytes)
        try? corruptFixture.cleanup()
        return reporter.failureCount
    }

    private static func runDiskFailureCases() -> Int {
        let reporter = SelfTestReporter()
        let fixture = SelfTestTemporaryDirectory(prefix: "movebreak-outbox-disk")
        do { try fixture.create(permissions: 0o700) }
        catch { reporter.check("Disk failure fixture created", false, detail: "\(error)") }
        let logger = SessionLogger(supportDir: fixture.url, currentOrigin: { originA })
        reporter.check("Disk fixture rejects history writes", symlink("missing-history", logger.logFile.path) == 0)
        let result = LockedBox<Result<SessionRecord, Error>?>(nil)
        var diagnostic = ""
        do {
            let captured = try SelfTestSupport.captureOutput {
                logger.logCompletion(completion: completion()) { result.value = $0 }
                _ = eventually {
                    if case .failure? = result.value { return true }
                    return false
                }
            }
            diagnostic = captured.stderr
        } catch {
            reporter.check("Disk failure diagnostic is captured", false, detail: "\(error)")
        }
        reporter.check("Disk failure is surfaced instead of acknowledging Done", eventually {
            if case .failure? = result.value { return true }
            return false
        })
        reporter.check(
            "Disk failure emits an observable persistence diagnostic",
            diagnostic.contains("SessionLogger persistence failure: Failed to read session data")
        )
        reporter.check("Disk failure performs no network work",
            !FileManager.default.fileExists(atPath: logger.logFile.path))
        _ = chmod(fixture.url.path, 0o700)
        try? fixture.cleanup()
        return reporter.failureCount
    }

    private static func runPermissionCases() -> Int {
        let reporter = SelfTestReporter()
        let fixture = SelfTestTemporaryDirectory(prefix: "movebreak-permissions")
        let logger = SessionLogger(supportDir: fixture.url)
        do {
            try logger.append(SessionRecord(routine: completion().routine, checkedIDs: []))
            reporter.check("Application support directory is 0700",
                SelfTestSupport.posixMode(at: fixture.url.path) == 0o700)
            reporter.check("Local history is 0600",
                SelfTestSupport.posixMode(at: logger.logFile.path) == 0o600)
        } catch {
            reporter.check("Permission cases complete", false, detail: "\(error)")
        }
        try? fixture.cleanup()
        return reporter.failureCount
    }

    private static func runFileBoundaryCases() -> Int {
        let reporter = SelfTestReporter()
        let fixture = SelfTestTemporaryDirectory(prefix: "movebreak-file-boundaries")
        func rejects(_ body: () throws -> Void) -> Bool {
            do { try body(); return false } catch { return true }
        }
        do {
            try fixture.create(permissions: 0o755)
            let store = try PrivateFileStore(directoryURL: fixture.url)
            let original = Data("original".utf8)
            try store.replace(original, at: "target")
            let target = fixture.url.appendingPathComponent("target")
            _ = chmod(target.path, 0o644)
            reporter.check("Existing data tightens before read", try store.read("target") == original
                && SelfTestSupport.posixMode(at: target.path) == 0o600
                && SelfTestSupport.posixMode(at: fixture.url.path) == 0o700)
            reporter.check("Failed partial staging write preserves original", try rejects {
                try store.replace(Data("replacement".utf8), at: "target", write: { handle, _ in
                    try handle.write(contentsOf: Data("partial".utf8))
                    throw CocoaError(.fileWriteOutOfSpace)
                })
            } && (try store.read("target")) == original)
            reporter.check("Failed rename preserves original", try rejects {
                try store.replace(Data(), at: "target", renameFile: { _, _, _, _ in errno = EIO; return -1 })
            } && (try store.read("target")) == original)
            var sameDirectory = false
            try store.replace(Data("new".utf8), at: "target", renameFile: { source, name, destination, target in
                sameDirectory = source == destination && !name.contains("/")
                return renameat(source, name, destination, target)
            })
            reporter.check("Atomic replacement stays in protected directory", try sameDirectory
                && (try store.read("target")) == Data("new".utf8))
            reporter.check("Failed and successful replacements clean staging files",
                try FileManager.default.contentsOfDirectory(atPath: fixture.url.path) == ["target"])
            reporter.check("Permission failure fixture is immutable", chflags(target.path, UInt32(UF_IMMUTABLE)) == 0)
            let permissionFailure = rejects { _ = try store.read("target") }
                && rejects { try store.append(Data("bad".utf8), to: "target") }
                && rejects { try store.replace(Data("bad".utf8), at: "target") }
            let unlocked = chflags(target.path, 0) == 0
            reporter.check("Failed permission tightening rejects access and preserves original",
                try permissionFailure && unlocked && Data(contentsOf: target) == Data("new".utf8))

            let outside = fixture.url.appendingPathComponent("sentinel")
            try original.write(to: outside)
            _ = chmod(outside.path, 0o644)
            for kind in ["symlink", "dangling", "directory", "fifo", "hardlink"] {
                let path = fixture.url.appendingPathComponent(kind).path
                switch kind {
                case "symlink": _ = symlink(outside.path, path)
                case "dangling": _ = symlink("absent", path)
                case "directory": try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
                case "fifo": _ = mkfifo(path, 0o600)
                default: _ = link(outside.path, path)
                }
                reporter.check("Reject \(kind) on read, append and replace",
                    rejects { _ = try store.read(kind) }
                    && rejects { try store.append(Data(), to: kind) }
                    && rejects { try store.replace(Data(), at: kind) })
            }
            reporter.check("Rejected indirection leaves destination bytes and mode unchanged",
                try Data(contentsOf: outside) == original && SelfTestSupport.posixMode(at: outside.path) == 0o644)
            let alias = fixture.url.appendingPathComponent("alias")
            _ = symlink(fixture.url.path, alias.path)
            reporter.check("Reject directory indirection including ancestor components", rejects {
                _ = try PrivateFileStore(directoryURL: alias.appendingPathComponent("child"))
            })

            let logger = SessionLogger(supportDir: fixture.url)
            let outbox = GroundworkOutbox(supportDir: fixture.url, currentOrigin: { nil })
            _ = symlink(outside.path, logger.logFile.path)
            _ = symlink(outside.path, outbox.fileURL.path)
            reporter.check("History and outbox reads reject symlink artifacts",
                rejects { _ = try logger.readHistory() } && rejects { _ = try outbox.readDocument() })
            reporter.check("History append rejects symlink artifact", rejects {
                try logger.append(SessionRecord(completion: completion(), destination: nil))
            })
            let result = LockedBox<Result<Void, Error>?>(nil)
            outbox.enqueue(SessionRecord(completion: completion(), destination: nil)) { result.value = $0 }
            reporter.check("Outbox enqueue fails closed on suspicious artifact", eventually {
                if case .failure? = result.value { return true }; return false
            })
            try fixture.cleanup()
        } catch {
            reporter.check("File boundary fixtures complete", false, detail: "\(error)")
            try? fixture.cleanup()
        }
        return reporter.failureCount
    }

    static func run() -> Int {
        var failures = 0
        print("Session record backward compatibility & stable completion identity")
        failures += runSessionRecordCases()
        print("")
        print("Durable history/outbox boundaries & relaunch recovery")
        failures += runDurabilityAndRecoveryCases()
        print("")
        print("Idempotent retry after lost response & duplicate receipt")
        failures += runRetryAndReceiptCases()
        print("")
        print("Groundwork HTTP failure classification & Retry-After")
        failures += runFailureClassificationCases()
        print("")
        print("Destination binding, explicit reassignment & legacy isolation")
        failures += runDestinationAndLegacyIsolationCases()
        print("")
        print("Concurrent enqueue & corrupt outbox preservation")
        failures += runConcurrentAndCorruptionCases()
        print("")
        print("Disk failure observability & protected file modes")
        failures += runDiskFailureCases()
        failures += runPermissionCases()
        failures += runFileBoundaryCases()
        return failures
    }
}

private final class LockedBox<Value> {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
    func withValue(_ body: (inout Value) -> Void) { lock.withLock { body(&storage) } }
}
