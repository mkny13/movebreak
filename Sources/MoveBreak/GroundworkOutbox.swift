import Foundation

enum GroundworkOutboxItemState: String, Codable {
    case queued
    case retryScheduled
    case authenticationPaused
    case permanentFailure
}

struct GroundworkOutboxItem: Codable, Equatable {
    let request: GroundworkCompletionRequest
    var destination: GroundworkOrigin?
    var state: GroundworkOutboxItemState
    var attemptCount: Int
    var nextAttemptAt: Date?
    var lastFailure: String?
}

struct GroundworkDeliveredReceipt: Codable, Equatable {
    let clientSessionID: UUID
    let destination: GroundworkOrigin
    let acceptedAt: Date
}

struct GroundworkOutboxDocument: Codable, Equatable {
    let schemaVersion: Int
    var items: [GroundworkOutboxItem]
    var delivered: [GroundworkDeliveredReceipt]
}

struct GroundworkOutboxStatus: Equatable {
    var pending = 0
    var failed = 0

    var summary: String {
        if pending == 0 && failed == 0 { return "Groundwork Sync: Up to Date" }
        if failed == 0 { return "Groundwork Sync: \(pending) Pending" }
        return "Groundwork Sync: \(pending) Pending, \(failed) Needs Attention"
    }
}

enum GroundworkOutboxError: Error, LocalizedError {
    case readFailed
    case malformed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .readFailed: return "The Groundwork outbox could not be read."
        case .malformed: return "The Groundwork outbox is malformed and was preserved."
        case .writeFailed: return "The Groundwork outbox could not be saved."
        }
    }
}

extension Notification.Name {
    static let groundworkOutboxChanged = Notification.Name("MoveBreakGroundworkOutboxChanged")
}

/// Versioned, origin-bound durable delivery queue. All document mutations occur on one queue
/// and use same-directory atomic replacement. Successful UUIDs remain in a receipt ledger so
/// history reconciliation cannot recreate already acknowledged work.
final class GroundworkOutbox {
    static let schemaVersion = 1
    static let shared = GroundworkOutbox()

    typealias ClientFactory = (GroundworkOrigin) throws -> GroundworkClient?

    let fileURL: URL
    private let supportDir: URL
    private let fileManager: FileManager
    private let queue: DispatchQueue
    private let now: () -> Date
    private let jitter: () -> Double
    private let currentOrigin: () -> GroundworkOrigin?
    private let clientFactory: ClientFactory
    private let statusLock = NSLock()
    private var cachedStatus = GroundworkOutboxStatus()
    private var isSending = false
    private var scheduledGeneration: UInt = 0

    init(
        supportDir: URL? = nil,
        fileManager: FileManager = .default,
        queue: DispatchQueue = DispatchQueue(label: "com.mike.MoveBreak.groundworkOutbox"),
        now: @escaping () -> Date = Date.init,
        jitter: @escaping () -> Double = { Double.random(in: 0.8...1.2) },
        currentOrigin: @escaping () -> GroundworkOrigin? = {
            Preferences.groundworkBaseURL.flatMap(GroundworkOrigin.init)
        },
        clientFactory: @escaping ClientFactory = { origin in
            guard let token = try Keychain.get(
                forAccount: origin.string,
                service: GroundworkClient.tokenService
            ), let url = origin.url else { return nil }
            return try GroundworkClient(baseURL: url, token: token)
        }
    ) {
        self.fileManager = fileManager
        self.queue = queue
        self.now = now
        self.jitter = jitter
        self.currentOrigin = currentOrigin
        self.clientFactory = clientFactory
        if let supportDir {
            self.supportDir = supportDir
        } else {
            self.supportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MoveBreak", isDirectory: true)
        }
        self.fileURL = self.supportDir.appendingPathComponent("groundwork-outbox-v1.json")
        refreshStatusFromDisk()
    }

    var status: GroundworkOutboxStatus { statusLock.withLock { cachedStatus } }

    func enqueue(_ record: SessionRecord, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            guard let request = record.groundworkCompletion else {
                completion(.success(()))
                return
            }
            do {
                var document = try self.readDocument()
                guard !document.delivered.contains(where: { $0.clientSessionID == request.clientSessionID }) else {
                    completion(.success(()))
                    return
                }
                if !document.items.contains(where: { $0.request.clientSessionID == request.clientSessionID }) {
                    document.items.append(GroundworkOutboxItem(
                        request: request,
                        destination: record.groundworkDestination,
                        state: .queued,
                        attemptCount: 0,
                        nextAttemptAt: nil,
                        lastFailure: record.groundworkDestination == nil ? "Groundwork is not configured." : nil
                    ))
                    try self.writeDocument(document)
                }
                self.publishStatus(document)
                completion(.success(()))
                self.drainOnQueue()
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Repairs a crash after history append but before outbox creation. Legacy history entries
    /// have no structured payload and are deliberately ignored.
    func recover(records: [SessionRecord], completion: ((Result<Void, Error>) -> Void)? = nil) {
        queue.async {
            do {
                var document = try self.readDocument()
                var known = Set(document.items.map { $0.request.clientSessionID })
                    .union(document.delivered.map(\.clientSessionID))
                var inserted = false
                for record in records where record.groundworkCompletion != nil && !known.contains(record.id) {
                    guard let request = record.groundworkCompletion else { continue }
                    document.items.append(GroundworkOutboxItem(
                        request: request,
                        destination: record.groundworkDestination,
                        state: .queued,
                        attemptCount: 0,
                        nextAttemptAt: nil,
                        lastFailure: record.groundworkDestination == nil ? "Groundwork is not configured." : nil
                    ))
                    known.insert(request.clientSessionID)
                    inserted = true
                }
                if inserted { try self.writeDocument(document) }
                self.publishStatus(document)
                completion?(.success(()))
                self.drainOnQueue()
            } catch {
                completion?(.failure(error))
            }
        }
    }

    func drain() { queue.async { self.drainOnQueue() } }

    /// User-initiated retry also explicitly binds previously unconfigured records to the
    /// currently configured origin. Records already bound to another origin are never moved.
    func retryFailed() {
        queue.async {
            do {
                var document = try self.readDocument()
                let origin = self.currentOrigin()
                for index in document.items.indices {
                    if document.items[index].destination == nil { document.items[index].destination = origin }
                    document.items[index].state = .queued
                    document.items[index].nextAttemptAt = nil
                    document.items[index].lastFailure = document.items[index].destination == nil
                        ? "Groundwork is not configured." : nil
                }
                try self.writeDocument(document)
                self.publishStatus(document)
                self.drainOnQueue()
            } catch {
                self.report("manual retry", error: error)
            }
        }
    }

    func readDocument() throws -> GroundworkOutboxDocument {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return GroundworkOutboxDocument(schemaVersion: Self.schemaVersion, items: [], delivered: [])
        }
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch { throw GroundworkOutboxError.readFailed }
        let document: GroundworkOutboxDocument
        do { document = try GroundworkCoding.decoder().decode(GroundworkOutboxDocument.self, from: data) }
        catch { throw GroundworkOutboxError.malformed }
        guard document.schemaVersion == Self.schemaVersion else { throw GroundworkOutboxError.malformed }
        try? fileManager.setAttributes([.posixPermissions: SessionLogger.filePermissions], ofItemAtPath: fileURL.path)
        return document
    }

    private func writeDocument(_ document: GroundworkOutboxDocument) throws {
        do {
            try fileManager.createDirectory(
                at: supportDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: SessionLogger.directoryPermissions]
            )
        } catch { throw GroundworkOutboxError.writeFailed }
        let data: Data
        do { data = try GroundworkCoding.encoder().encode(document) }
        catch { throw GroundworkOutboxError.writeFailed }
        let temporary = supportDir.appendingPathComponent(".groundwork-outbox.\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: SessionLogger.filePermissions]
        ) else { throw GroundworkOutboxError.writeFailed }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.synchronize()
        } catch { throw GroundworkOutboxError.writeFailed }
        guard rename(temporary.path, fileURL.path) == 0 else { throw GroundworkOutboxError.writeFailed }
    }

    private func drainOnQueue() {
        guard !isSending else { return }
        let document: GroundworkOutboxDocument
        do { document = try readDocument() } catch {
            report("drain", error: error)
            return
        }
        publishStatus(document)
        let current = now()
        guard let index = document.items.firstIndex(where: {
            switch $0.state {
            case .queued: return true
            case .retryScheduled: return ($0.nextAttemptAt ?? .distantPast) <= current
            case .authenticationPaused, .permanentFailure: return false
            }
        }) else {
            scheduleNextAttempt(document)
            return
        }
        let item = document.items[index]
        guard let destination = item.destination else { return }
        let client: GroundworkClient?
        do { client = try clientFactory(destination) } catch {
            pause(index: index, document: document, failure: "Groundwork credentials could not be read.")
            return
        }
        guard let client else {
            pause(index: index, document: document, failure: "Groundwork credentials are unavailable for \(destination.string).")
            return
        }
        isSending = true
        client.postCompletion(item.request) { [weak self] result in
            self?.queue.async { self?.handle(result, clientSessionID: item.request.clientSessionID) }
        }
    }

    private func handle(
        _ result: Result<GroundworkCompletionReceipt, GroundworkClientError>,
        clientSessionID: UUID
    ) {
        isSending = false
        do {
            var document = try readDocument()
            guard let index = document.items.firstIndex(where: {
                $0.request.clientSessionID == clientSessionID
            }) else { return }
            switch result {
            case .success(let receipt):
                guard let destination = document.items[index].destination,
                      receipt.clientSessionID == clientSessionID else {
                    document.items[index].state = .permanentFailure
                    document.items[index].lastFailure = "Groundwork returned a mismatched receipt."
                    break
                }
                document.items.remove(at: index)
                if !document.delivered.contains(where: { $0.clientSessionID == clientSessionID }) {
                    document.delivered.append(GroundworkDeliveredReceipt(
                        clientSessionID: clientSessionID,
                        destination: destination,
                        acceptedAt: receipt.acceptedAt
                    ))
                }
            case .failure(.authentication):
                document.items[index].state = .authenticationPaused
                document.items[index].lastFailure = "Groundwork authentication failed; reconfigure and retry."
            case .failure(.permanent(let status)):
                document.items[index].state = .permanentFailure
                document.items[index].lastFailure = "Groundwork rejected this completion (HTTP \(status))."
            case .failure(.retryable(_, let retryAfter)):
                scheduleRetry(index: index, document: &document, retryAfter: retryAfter)
            case .failure(.timedOut):
                scheduleRetry(index: index, document: &document, retryAfter: nil)
            case .failure(.cancelled), .failure(.malformedResponse), .failure(.unsupportedSchema),
                 .failure(.invalidConfiguration):
                document.items[index].state = .permanentFailure
                document.items[index].lastFailure = "Groundwork returned an unusable response."
            }
            try writeDocument(document)
            publishStatus(document)
            drainOnQueue()
        } catch { report("delivery result", error: error) }
    }

    private func scheduleRetry(
        index: Int,
        document: inout GroundworkOutboxDocument,
        retryAfter: TimeInterval?
    ) {
        document.items[index].attemptCount += 1
        let exponent = min(document.items[index].attemptCount - 1, 8)
        let boundedBackoff = min(5 * pow(2, Double(exponent)) * max(0.5, min(jitter(), 1.5)), 300)
        let delay = min(max(retryAfter ?? boundedBackoff, 1), 86_400)
        document.items[index].state = .retryScheduled
        document.items[index].nextAttemptAt = now().addingTimeInterval(delay)
        document.items[index].lastFailure = "Groundwork is unavailable; retry scheduled."
    }

    private func pause(index: Int, document original: GroundworkOutboxDocument, failure: String) {
        var document = original
        document.items[index].state = .authenticationPaused
        document.items[index].lastFailure = failure
        do {
            try writeDocument(document)
            publishStatus(document)
        } catch { report("pause", error: error) }
    }

    private func scheduleNextAttempt(_ document: GroundworkOutboxDocument) {
        guard let date = document.items.compactMap({ item -> Date? in
            item.state == .retryScheduled ? item.nextAttemptAt : nil
        }).min() else { return }
        scheduledGeneration &+= 1
        let generation = scheduledGeneration
        queue.asyncAfter(deadline: .now() + max(0, date.timeIntervalSince(now()))) { [weak self] in
            guard let self, generation == self.scheduledGeneration else { return }
            self.drainOnQueue()
        }
    }

    private func refreshStatusFromDisk() {
        do { publishStatus(try readDocument()) }
        catch { cachedStatus = GroundworkOutboxStatus(pending: 0, failed: 1) }
    }

    private func publishStatus(_ document: GroundworkOutboxDocument) {
        let status = GroundworkOutboxStatus(
            pending: document.items.count,
            failed: document.items.filter {
                $0.destination == nil || $0.state == .authenticationPaused || $0.state == .permanentFailure
            }.count
        )
        statusLock.withLock { cachedStatus = status }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .groundworkOutboxChanged, object: self)
        }
    }

    private func report(_ operation: String, error: Error) {
        FileHandle.standardError.write(Data("Groundwork outbox \(operation) failed; data preserved.\n".utf8))
        statusLock.withLock { cachedStatus.failed = max(1, cachedStatus.failed) }
    }
}

extension GroundworkOrigin {
    var url: URL? { URL(string: string) }
}
