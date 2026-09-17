import Foundation

/// Typed errors produced during SessionLogger operations.
enum SessionLoggerError: Error, LocalizedError, CustomStringConvertible, Equatable {
    case encodingFailed(String)
    case decodingFailed(String)
    case readFailed(String)
    case writeFailed(String)
    case directoryCreationFailed(String)

    var description: String {
        switch self {
        case .encodingFailed(let msg): return "Failed to encode session record: \(msg)"
        case .decodingFailed(let msg): return "Failed to decode session record: \(msg)"
        case .readFailed(let msg): return "Failed to read session data: \(msg)"
        case .writeFailed(let msg): return "Failed to write session data: \(msg)"
        case .directoryCreationFailed(let msg): return "Failed to create application support directory: \(msg)"
        }
    }

    var errorDescription: String? { description }
}

/// Local session history plus a best-effort push to Notion. The JSONL file is the source of
/// truth — it's written before any network call, so a completed session is never lost even if
/// Notion is unreachable or unconfigured.
final class SessionLogger {
    static let shared = SessionLogger()

    static let directoryPermissions: NSNumber = 0o700
    static let filePermissions: NSNumber = 0o600

    private let queue: DispatchQueue
    private let deliver: (SessionRecord, @escaping (Result<Void, Error>) -> Void) -> Void
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    let supportDir: URL
    let logFile: URL
    let pendingFile: URL
    private let fileManager: FileManager

    init(
        supportDir: URL? = nil,
        fileManager: FileManager = .default,
        queue: DispatchQueue = DispatchQueue(label: "com.mike.MoveBreak.sessionLogger"),
        deliver: @escaping (SessionRecord, @escaping (Result<Void, Error>) -> Void) -> Void = NotionClient.createSessionPage
    ) {
        self.fileManager = fileManager
        self.queue = queue
        self.deliver = deliver
        let dir: URL
        if let supportDir = supportDir {
            dir = supportDir
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dir = base.appendingPathComponent("MoveBreak", isDirectory: true)
        }
        self.supportDir = dir
        self.logFile = dir.appendingPathComponent("sessions.jsonl")
        self.pendingFile = dir.appendingPathComponent("pending-sync.json")
        self.ensureSupportDirectoryAndPermissions()
    }

    /// Creates or tightens permissions on the support directory and any contained files.
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

        // Tighten existing files inside supportDir to owner-only read/write (0600)
        if let contents = try? fileManager.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
            for item in contents {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let perm = isDir ? Self.directoryPermissions : Self.filePermissions
                try? fileManager.setAttributes([.posixPermissions: perm], ofItemAtPath: item.path)
            }
        }
    }

    func logCompletion(
        routine: Routine,
        checkedIDs: Set<String>,
        completion: ((Result<SessionRecord, Error>) -> Void)? = nil
    ) {
        let record = SessionRecord(routine: routine, checkedIDs: checkedIDs)
        logCompletion(record: record, completion: completion)
    }

    func logCompletion(
        record: SessionRecord,
        completion: ((Result<SessionRecord, Error>) -> Void)? = nil
    ) {
        queue.async {
            do {
                try self.append(record, to: self.logFile)
            } catch {
                FileHandle.standardError.write(Data("SessionLogger persistence failure: \(error.localizedDescription)\n".utf8))
                completion?(.failure(error))
                return
            }

            // Local write succeeded
            completion?(.success(record))
            self.push(record)
        }
    }

    /// Call once at launch to flush anything that failed to reach Notion last run.
    func retryPendingSyncs() {
        queue.async {
            let pending: [SessionRecord]
            do {
                pending = try self.readPending()
            } catch {
                self.reportPendingReadFailure(operation: "retry", error: error)
                return
            }
            guard !pending.isEmpty else { return }
            for record in pending {
                self.push(record)
            }
        }
    }

    // MARK: - Notion push

    private func push(_ record: SessionRecord) {
        deliver(record) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success:
                    self.removeFromPending(record.id)
                case .failure:
                    self.addToPending(record)
                }
            }
        }
    }

    // MARK: - sessions.jsonl (append-only, mode 0600)

    func append(_ record: SessionRecord, to file: URL? = nil) throws {
        let targetFile = file ?? logFile
        let line: Data
        do {
            line = try encoder.encode(record)
        } catch {
            throw SessionLoggerError.encodingFailed(error.localizedDescription)
        }
        var data = line
        data.append(UInt8(ascii: "\n"))

        if fileManager.fileExists(atPath: targetFile.path) {
            try? fileManager.setAttributes([.posixPermissions: Self.filePermissions], ofItemAtPath: targetFile.path)
            do {
                let handle = try FileHandle(forWritingTo: targetFile)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                throw SessionLoggerError.writeFailed("Append failed: \(error.localizedDescription)")
            }
        } else {
            guard fileManager.createFile(atPath: targetFile.path, contents: data, attributes: [.posixPermissions: Self.filePermissions]) else {
                throw SessionLoggerError.writeFailed("Failed to create file at \(targetFile.path)")
            }
        }
    }

    // MARK: - pending-sync.json (atomic replacement, mode 0600)

    func readPending() throws -> [SessionRecord] {
        guard fileManager.fileExists(atPath: pendingFile.path) else {
            return []
        }
        let data: Data
        do {
            data = try Data(contentsOf: pendingFile)
        } catch {
            throw SessionLoggerError.readFailed(error.localizedDescription)
        }
        try? fileManager.setAttributes([.posixPermissions: Self.filePermissions], ofItemAtPath: pendingFile.path)
        do {
            return try decoder.decode([SessionRecord].self, from: data)
        } catch {
            throw SessionLoggerError.decodingFailed(error.localizedDescription)
        }
    }

    func writePending(_ records: [SessionRecord]) throws {
        let data: Data
        do {
            data = try encoder.encode(records)
        } catch {
            throw SessionLoggerError.encodingFailed(error.localizedDescription)
        }

        let tempFile = supportDir.appendingPathComponent(".\(pendingFile.lastPathComponent).tmp.\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: tempFile)
        }

        guard fileManager.createFile(atPath: tempFile.path, contents: data, attributes: [.posixPermissions: Self.filePermissions]) else {
            throw SessionLoggerError.writeFailed("Failed to create temporary file at \(tempFile.path)")
        }

        // Atomically replace target file using rename() within the same directory
        if rename(tempFile.path, pendingFile.path) != 0 {
            let err = String(cString: strerror(errno))
            throw SessionLoggerError.writeFailed("Atomic rename failed: \(err)")
        }
    }

    private func addToPending(_ record: SessionRecord) {
        let records: [SessionRecord]
        do {
            records = try readPending()
        } catch {
            reportPendingReadFailure(operation: "add", error: error)
            return
        }
        guard !records.contains(where: { $0.id == record.id }) else { return }
        do {
            try writePending(records + [record])
        } catch {
            FileHandle.standardError.write(Data("SessionLogger pending-sync add failed: \(error.localizedDescription)\n".utf8))
        }
    }

    private func removeFromPending(_ id: UUID) {
        var records: [SessionRecord]
        do {
            records = try readPending()
        } catch {
            reportPendingReadFailure(operation: "remove", error: error)
            return
        }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records.remove(at: index)
        do {
            try writePending(records)
        } catch {
            FileHandle.standardError.write(Data("SessionLogger pending-sync remove failed: \(error.localizedDescription)\n".utf8))
        }
    }

    private func reportPendingReadFailure(operation: String, error: Error) {
        let category: String
        switch error {
        case SessionLoggerError.decodingFailed:
            category = "malformed data"
        case SessionLoggerError.readFailed:
            category = "unreadable data"
        default:
            category = "read error"
        }
        FileHandle.standardError.write(Data(
            "SessionLogger pending-sync \(operation) aborted; existing queue preserved (\(category)).\n".utf8
        ))
    }
}
