import CryptoKit
import Darwin
import Foundation

struct GroundworkCachedRoutine: Equatable {
    let response: GroundworkRoutineResponse
    let cachedAt: Date
    let label: String
}

enum GroundworkCacheLookup: Equatable {
    case missing
    case corrupt
    case found(GroundworkCachedRoutine)
}

enum GroundworkRoutineAvailability {
    case unconfigured(localRoutines: [Routine], label: String)
    case live(GroundworkRoutineResponse)
    case validEmpty(generatedAt: Date)
    case authFailed
    case unavailable(cached: GroundworkCachedRoutine?)
    case malformed(cached: GroundworkCachedRoutine?)
    case bundledDefaults(routines: [Routine], label: String)
}

final class GroundworkRoutineCache {
    private struct Record: Codable {
        let schemaVersion: Int
        let origin: GroundworkOrigin
        let locationID: String
        let durationMinutes: Int
        let cachedAt: Date
        let response: GroundworkRoutineResponse
    }

    let directoryURL: URL

    init(directoryURL: URL? = nil) {
        self.directoryURL = directoryURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("MoveBreak/GroundworkRoutineCache", isDirectory: true)
    }

    func store(
        _ response: GroundworkRoutineResponse,
        origin: GroundworkOrigin,
        locationID: String,
        durationMinutes: Int,
        cachedAt: Date = Date()
    ) throws {
        try response.validate()
        guard response.routine != nil else { return } // A valid empty response must remain empty.
        try ensureDirectory()
        let record = Record(
            schemaVersion: GroundworkSchema.version,
            origin: origin,
            locationID: locationID,
            durationMinutes: durationMinutes,
            cachedAt: cachedAt,
            response: response
        )
        let data = try GroundworkCoding.encoder().encode(record)
        let destination = fileURL(origin: origin, locationID: locationID, durationMinutes: durationMinutes)
        try data.write(to: destination, options: [.atomic])
        guard chmod(destination.path, 0o600) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    func load(origin: GroundworkOrigin, locationID: String, durationMinutes: Int) -> GroundworkCacheLookup {
        let url = fileURL(origin: origin, locationID: locationID, durationMinutes: durationMinutes)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let record = try GroundworkCoding.decoder().decode(Record.self, from: Data(contentsOf: url))
            guard record.schemaVersion == GroundworkSchema.version,
                  record.origin == origin,
                  record.locationID == locationID,
                  record.durationMinutes == durationMinutes,
                  record.response.routine != nil else { return .corrupt }
            try record.response.validate()
            return .found(GroundworkCachedRoutine(
                response: record.response,
                cachedAt: record.cachedAt,
                label: "Offline copy from \(Self.displayDate(record.cachedAt)) — not revalidated"
            ))
        } catch {
            return .corrupt
        }
    }

    func resolve(
        result: Result<GroundworkRoutineResponse, GroundworkClientError>?,
        origin: GroundworkOrigin?,
        locationID: String,
        durationMinutes: Int,
        localRoutines: [Routine]
    ) -> GroundworkRoutineAvailability {
        guard let result, let origin else {
            return .unconfigured(
                localRoutines: localRoutines,
                label: "Bundled/local routines — not clinically revalidated"
            )
        }
        switch result {
        case .success(let response):
            if response.routine == nil { return .validEmpty(generatedAt: response.generatedAt) }
            try? store(response, origin: origin, locationID: locationID, durationMinutes: durationMinutes)
            return .live(response)
        case .failure(.authentication):
            return .authFailed
        case .failure(.malformedResponse), .failure(.unsupportedSchema):
            return .malformed(cached: cached(origin: origin, locationID: locationID, durationMinutes: durationMinutes))
        case .failure:
            let cached = cached(origin: origin, locationID: locationID, durationMinutes: durationMinutes)
            if cached != nil { return .unavailable(cached: cached) }
            return .bundledDefaults(
                routines: localRoutines,
                label: "Bundled/local fallback — Groundwork unavailable; not clinically revalidated"
            )
        }
    }

    private func cached(origin: GroundworkOrigin, locationID: String, durationMinutes: Int) -> GroundworkCachedRoutine? {
        if case .found(let value) = load(origin: origin, locationID: locationID, durationMinutes: durationMinutes) {
            return value
        }
        return nil
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directoryURL.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private func fileURL(origin: GroundworkOrigin, locationID: String, durationMinutes: Int) -> URL {
        let key = "\(GroundworkSchema.version)|\(origin.string)|\(locationID)|\(durationMinutes)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent("routine-\(digest).json")
    }

    private static func displayDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
