import Foundation

enum GroundworkSchema {
    static let version = 1
}

enum GroundworkTreadmillSafety: String, Codable {
    case walkSafe = "walk_safe"
    case pauseBelt = "pause_belt"
}

struct GroundworkDose: Codable, Equatable {
    let sets: Int?
    let reps: Int?
    let holdSeconds: Int?
    let side: String?

    func validate() throws {
        for value in [sets, reps, holdSeconds].compactMap({ $0 }) where value < 0 {
            throw GroundworkModelError.invalid("dose values must be nonnegative")
        }
        if sets == nil && reps == nil && holdSeconds == nil {
            throw GroundworkModelError.invalid("dose must contain a measurable value")
        }
    }
}

struct GroundworkWarning: Codable, Equatable {
    let ruleID: String
    let message: String
    let rationale: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case ruleID = "ruleId"
        case message, rationale, source
    }

    func validate() throws {
        try requireNonempty([ruleID, message, rationale, source], label: "warning")
    }
}

struct GroundworkRoutineItem: Codable, Equatable {
    let id: String
    let exerciseID: String
    let prescriptionID: String
    let name: String
    let cues: [String]
    let plannedDose: GroundworkDose
    let inclusionReasons: [String]
    let treadmillSafety: GroundworkTreadmillSafety
    let warnings: [GroundworkWarning]

    enum CodingKeys: String, CodingKey {
        case id
        case exerciseID = "exerciseId"
        case prescriptionID = "prescriptionId"
        case name, cues, plannedDose, inclusionReasons, treadmillSafety, warnings
    }

    func validate() throws {
        try requireNonempty([id, exerciseID, prescriptionID, name], label: "routine item")
        guard !cues.isEmpty, cues.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw GroundworkModelError.invalid("routine item cues must be nonempty")
        }
        guard !inclusionReasons.isEmpty,
              inclusionReasons.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw GroundworkModelError.invalid("routine item inclusion reasons must be nonempty")
        }
        try plannedDose.validate()
        try warnings.forEach { try $0.validate() }
    }
}

struct GroundworkRoutine: Codable, Equatable {
    let id: String
    let title: String
    let durationMinutes: Int
    let locationID: String
    let posture: String
    let items: [GroundworkRoutineItem]
    let warnings: [GroundworkWarning]

    enum CodingKeys: String, CodingKey {
        case id, title, durationMinutes
        case locationID = "locationId"
        case posture, items, warnings
    }

    func validate() throws {
        try requireNonempty([id, title, locationID, posture], label: "routine")
        guard (1...30).contains(durationMinutes) else {
            throw GroundworkModelError.invalid("routine duration is outside 1...30 minutes")
        }
        guard !items.isEmpty, Set(items.map(\.id)).count == items.count else {
            throw GroundworkModelError.invalid("routine items must be nonempty with unique IDs")
        }
        try items.forEach { try $0.validate() }
        try warnings.forEach { try $0.validate() }
    }
}

struct GroundworkRoutineResponse: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let routine: GroundworkRoutine?

    func validate() throws {
        guard schemaVersion == GroundworkSchema.version else {
            throw GroundworkModelError.unsupportedSchema(schemaVersion)
        }
        try routine?.validate()
    }
}

enum GroundworkProvenance: String, Codable {
    case live
    case cached
    case local
}

struct GroundworkActualDose: Codable, Equatable {
    let sets: Int?
    let reps: Int?
    let holdSeconds: Int?
    let side: String?

    func validate() throws {
        for value in [sets, reps, holdSeconds].compactMap({ $0 }) where value < 0 {
            throw GroundworkModelError.invalid("actual dose values must be nonnegative")
        }
    }
}

struct GroundworkCompletedItem: Codable, Equatable {
    let itemID: String
    let actualDose: GroundworkActualDose

    enum CodingKeys: String, CodingKey {
        case itemID = "itemId"
        case actualDose
    }
}

struct GroundworkWarningOverride: Codable, Equatable {
    let ruleID: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case ruleID = "ruleId"
        case reason
    }
}

struct GroundworkCompletionRequest: Codable, Equatable {
    let schemaVersion: Int
    let clientSessionID: UUID
    let startedAt: Date
    let finishedAt: Date
    let provenance: GroundworkProvenance
    let routine: GroundworkRoutine
    let checkedItemIDs: [String]
    let completedItems: [GroundworkCompletedItem]
    let warningOverrides: [GroundworkWarningOverride]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case clientSessionID = "clientSessionId"
        case startedAt, finishedAt, provenance, routine
        case checkedItemIDs = "checkedItemIds"
        case completedItems, warningOverrides
    }

    func validate() throws {
        guard schemaVersion == GroundworkSchema.version else {
            throw GroundworkModelError.unsupportedSchema(schemaVersion)
        }
        guard finishedAt >= startedAt else {
            throw GroundworkModelError.invalid("finish time precedes start time")
        }
        try routine.validate()
        let itemIDs = Set(routine.items.map(\.id))
        guard Set(checkedItemIDs).count == checkedItemIDs.count,
              Set(checkedItemIDs).isSubset(of: itemIDs) else {
            throw GroundworkModelError.invalid("checked item IDs must be unique members of the routine")
        }
        guard completedItems.map(\.itemID) == checkedItemIDs else {
            throw GroundworkModelError.invalid("completed items must match checked item IDs in order")
        }
        try completedItems.forEach { try $0.actualDose.validate() }
        for override in warningOverrides {
            try requireNonempty([override.ruleID, override.reason], label: "warning override")
        }
    }
}

struct GroundworkCompletionReceipt: Codable, Equatable {
    let schemaVersion: Int
    let clientSessionID: UUID
    let acceptedAt: Date
    let duplicate: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case clientSessionID = "clientSessionId"
        case acceptedAt, duplicate
    }
}

enum GroundworkModelError: Error, Equatable {
    case unsupportedSchema(Int)
    case invalid(String)
}

private func requireNonempty(_ values: [String], label: String) throws {
    guard values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
        throw GroundworkModelError.invalid("\(label) contains an empty required field")
    }
}

enum GroundworkCoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = ISO8601DateFormatter.groundwork.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 UTC timestamp"
                )
            }
            return date
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter.groundwork.string(from: date))
        }
        return encoder
    }
}

private extension ISO8601DateFormatter {
    static let groundwork: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
