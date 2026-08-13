import Foundation

/// Local session history plus a best-effort push to Notion. The JSONL file is the source of
/// truth — it's written before any network call, so a completed session is never lost even if
/// Notion is unreachable or unconfigured.
final class SessionLogger {
    static let shared = SessionLogger()

    private let queue = DispatchQueue(label: "com.mike.MoveBreak.sessionLogger")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let supportDir: URL
    private let logFile: URL
    private let pendingFile: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        supportDir = base.appendingPathComponent("MoveBreak", isDirectory: true)
        logFile = supportDir.appendingPathComponent("sessions.jsonl")
        pendingFile = supportDir.appendingPathComponent("pending-sync.json")
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    }

    func logCompletion(routine: Routine, checkedIDs: Set<String>) {
        let record = SessionRecord(routine: routine, checkedIDs: checkedIDs)
        queue.async {
            self.append(record, to: self.logFile)
            self.push(record)
        }
    }

    /// Call once at launch to flush anything that failed to reach Notion last run.
    func retryPendingSyncs() {
        queue.async {
            let pending = self.readPending()
            guard !pending.isEmpty else { return }
            for record in pending {
                self.push(record)
            }
        }
    }

    // MARK: - Notion push

    private func push(_ record: SessionRecord) {
        NotionClient.createSessionPage(record) { [weak self] result in
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

    // MARK: - sessions.jsonl (append-only)

    private func append(_ record: SessionRecord, to file: URL) {
        guard let line = try? encoder.encode(record) else { return }
        var data = line
        data.append(UInt8(ascii: "\n"))

        if FileManager.default.fileExists(atPath: file.path) {
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: file)
        }
    }

    // MARK: - pending-sync.json

    private func readPending() -> [SessionRecord] {
        guard let data = try? Data(contentsOf: pendingFile),
              let records = try? decoder.decode([SessionRecord].self, from: data) else {
            return []
        }
        return records
    }

    private func writePending(_ records: [SessionRecord]) {
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: pendingFile)
    }

    private func addToPending(_ record: SessionRecord) {
        var records = readPending()
        guard !records.contains(where: { $0.id == record.id }) else { return }
        records.append(record)
        writePending(records)
    }

    private func removeFromPending(_ id: UUID) {
        var records = readPending()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records.remove(at: index)
        writePending(records)
    }
}
