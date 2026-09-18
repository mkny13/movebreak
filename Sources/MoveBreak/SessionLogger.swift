import Foundation

enum SessionLoggerError: Error, LocalizedError, CustomStringConvertible, Equatable {
    case encodingFailed(String)
    case decodingFailed(String)
    case readFailed(String)
    case writeFailed(String)
    case directoryCreationFailed(String)

    var description: String {
        switch self {
        case .encodingFailed(let message): return "Failed to encode session record: \(message)"
        case .decodingFailed(let message): return "Failed to decode session record: \(message)"
        case .readFailed(let message): return "Failed to read session data: \(message)"
        case .writeFailed(let message): return "Failed to write session data: \(message)"
        case .directoryCreationFailed(let message): return "Failed to create application support directory: \(message)"
        }
    }

    var errorDescription: String? { description }
}

/// Append-only local history. A structured completion is acknowledged only after both its
/// JSONL record and origin-bound outbox entry are durable. On launch, history repairs a crash
/// between those two writes; legacy records remain readable and are never uploaded.
final class SessionLogger {
    static let shared = SessionLogger(outbox: .shared)

    static let directoryPermissions: NSNumber = 0o700
    static let filePermissions: NSNumber = 0o600

    private let queue: DispatchQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileManager: FileManager
    private let outbox: GroundworkOutbox
    private let currentOrigin: () -> GroundworkOrigin?
    private var knownHistoryIDs: Set<UUID>?

    let supportDir: URL
    let logFile: URL

    init(
        supportDir: URL? = nil,
        fileManager: FileManager = .default,
        queue: DispatchQueue = DispatchQueue(label: "com.mike.MoveBreak.sessionLogger"),
        outbox: GroundworkOutbox? = nil,
        currentOrigin: @escaping () -> GroundworkOrigin? = {
            Preferences.groundworkBaseURL.flatMap(GroundworkOrigin.init)
        }
    ) {
        self.fileManager = fileManager
        self.queue = queue
        self.currentOrigin = currentOrigin
        let directory = supportDir ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("MoveBreak", isDirectory: true)
        self.supportDir = directory
        self.logFile = directory.appendingPathComponent("sessions.jsonl")
        self.outbox = outbox ?? GroundworkOutbox(supportDir: directory)
        ensureSupportDirectoryAndPermissions()
    }

    func ensureSupportDirectoryAndPermissions() {
        if !fileManager.fileExists(atPath: supportDir.path) {
            try? fileManager.createDirectory(
                at: supportDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: Self.directoryPermissions]
            )
        } else {
            try? fileManager.setAttributes(
                [.posixPermissions: Self.directoryPermissions],
                ofItemAtPath: supportDir.path
            )
        }
        if let contents = try? fileManager.contentsOfDirectory(
            at: supportDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for item in contents {
                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                try? fileManager.setAttributes(
                    [.posixPermissions: isDirectory ? Self.directoryPermissions : Self.filePermissions],
                    ofItemAtPath: item.path
                )
            }
        }
    }

    /// Compatibility entry point for local-only callers. New HUD completions use the structured
    /// overload below so their stable UUID and clinical snapshot survive relaunch.
    func logCompletion(
        routine: Routine,
        checkedIDs: Set<String>,
        completion: ((Result<SessionRecord, Error>) -> Void)? = nil
    ) {
        logCompletion(record: SessionRecord(routine: routine, checkedIDs: checkedIDs), completion: completion)
    }

    func logCompletion(
        completion routineCompletion: RoutineCompletion,
        callback: @escaping (Result<SessionRecord, Error>) -> Void
    ) {
        let record = SessionRecord(completion: routineCompletion, destination: currentOrigin())
        logCompletion(record: record, completion: callback)
    }

    func logCompletion(
        record: SessionRecord,
        completion: ((Result<SessionRecord, Error>) -> Void)? = nil
    ) {
        queue.async {
            do {
                try self.appendIfNeeded(record)
            } catch {
                self.report("persistence", error: error)
                completion?(.failure(error))
                return
            }
            guard record.groundworkCompletion != nil else {
                completion?(.success(record))
                return
            }
            self.outbox.enqueue(record) { result in
                switch result {
                case .success: completion?(.success(record))
                case .failure(let error):
                    self.report("outbox persistence", error: error)
                    completion?(.failure(error))
                }
            }
        }
    }

    /// Repairs persistence boundaries before attempting launch-time network delivery.
    func recoverAndRetry() {
        queue.async {
            do {
                let records = try self.readHistory()
                self.knownHistoryIDs = Set(records.map(\.id))
                self.outbox.recover(records: records)
            } catch {
                self.report("history recovery", error: error)
                // Corrupt history must not prevent already-durable outbox work from draining.
                self.outbox.drain()
            }
        }
    }

    func retryPendingSyncs() { outbox.retryFailed() }

    func append(_ record: SessionRecord, to file: URL? = nil) throws {
        let target = file ?? logFile
        let line: Data
        do { line = try encoder.encode(record) }
        catch { throw SessionLoggerError.encodingFailed(error.localizedDescription) }
        var data = line
        data.append(UInt8(ascii: "\n"))

        if fileManager.fileExists(atPath: target.path) {
            try? fileManager.setAttributes([.posixPermissions: Self.filePermissions], ofItemAtPath: target.path)
            do {
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.synchronize()
            } catch { throw SessionLoggerError.writeFailed("Append failed: \(error.localizedDescription)") }
        } else {
            guard fileManager.createFile(
                atPath: target.path,
                contents: data,
                attributes: [.posixPermissions: Self.filePermissions]
            ) else { throw SessionLoggerError.writeFailed("Failed to create history file") }
            do {
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                try handle.synchronize()
            } catch { throw SessionLoggerError.writeFailed("Sync failed: \(error.localizedDescription)") }
        }
    }

    func readHistory() throws -> [SessionRecord] {
        guard fileManager.fileExists(atPath: logFile.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: logFile) }
        catch { throw SessionLoggerError.readFailed(error.localizedDescription) }
        try? fileManager.setAttributes([.posixPermissions: Self.filePermissions], ofItemAtPath: logFile.path)
        var records: [SessionRecord] = []
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            do { records.append(try decoder.decode(SessionRecord.self, from: Data(line))) }
            catch { throw SessionLoggerError.decodingFailed(error.localizedDescription) }
        }
        return records
    }

    private func appendIfNeeded(_ record: SessionRecord) throws {
        if knownHistoryIDs == nil { knownHistoryIDs = Set(try readHistory().map(\.id)) }
        guard knownHistoryIDs?.contains(record.id) == false else { return }
        try append(record)
        knownHistoryIDs?.insert(record.id)
    }

    private func report(_ operation: String, error: Error) {
        FileHandle.standardError.write(Data("SessionLogger \(operation) failure: \(error.localizedDescription)\n".utf8))
    }
}
