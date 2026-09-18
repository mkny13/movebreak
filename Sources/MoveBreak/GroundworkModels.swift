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

    enum CodingKeys: String, CodingKey { case sets, reps, holdSeconds, side }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sets, forKey: .sets)
        try container.encode(reps, forKey: .reps)
        try container.encode(holdSeconds, forKey: .holdSeconds)
        try container.encode(side, forKey: .side)
    }

    func validate() throws {
        for value in [sets, reps, holdSeconds].compactMap({ $0 }) where value < 0 {
            throw GroundworkModelError.invalid("dose values must be nonnegative")
        }
        if sets == nil && reps == nil && holdSeconds == nil {
            throw GroundworkModelError.invalid("dose must contain a measurable value")
        }
    }

    var displayText: String {
        var components: [String] = []
        if let sets { components.append("\(sets) set\(sets == 1 ? "" : "s")") }
        if let reps { components.append("\(reps) rep\(reps == 1 ? "" : "s")") }
        if let holdSeconds { components.append("\(holdSeconds) sec hold") }
        if let side, !side.isEmpty { components.append(side.replacingOccurrences(of: "_", with: " ")) }
        return components.joined(separator: " · ")
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

struct GroundworkRoutineSnapshotItem: Codable, Equatable {
    let itemID: String
    let exerciseID: String?
    let prescriptionID: String?
    let name: String
    let cues: [String]
    let plannedDose: GroundworkDose?
    let warnings: [GroundworkWarning]

    enum CodingKeys: String, CodingKey {
        case itemID = "itemId"
        case exerciseID = "exerciseId"
        case prescriptionID = "prescriptionId"
        case name, cues, plannedDose, warnings
    }

    init(item: GroundworkRoutineItem) {
        itemID = item.id
        exerciseID = item.exerciseID
        prescriptionID = item.prescriptionID
        name = item.name
        cues = item.cues
        plannedDose = item.plannedDose
        warnings = item.warnings
    }

    init(
        itemID: String,
        exerciseID: String?,
        prescriptionID: String?,
        name: String,
        cues: [String],
        plannedDose: GroundworkDose?,
        warnings: [GroundworkWarning]
    ) {
        self.itemID = itemID
        self.exerciseID = exerciseID
        self.prescriptionID = prescriptionID
        self.name = name
        self.cues = cues
        self.plannedDose = plannedDose
        self.warnings = warnings
    }
}

struct GroundworkRoutineSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let routineID: String?
    let title: String
    let durationMinutes: Int
    let locationID: String?
    let posture: String?
    let items: [GroundworkRoutineSnapshotItem]
    let warnings: [GroundworkWarning]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case routineID = "routineId"
        case title, durationMinutes
        case locationID = "locationId"
        case posture, items, warnings
    }

    init(routine: GroundworkRoutine) {
        schemaVersion = GroundworkSchema.version
        routineID = routine.id
        title = routine.title
        durationMinutes = routine.durationMinutes
        locationID = routine.locationID
        posture = routine.posture
        items = routine.items.map(GroundworkRoutineSnapshotItem.init)
        warnings = routine.warnings
    }

    init(
        schemaVersion: Int = GroundworkSchema.version,
        routineID: String?,
        title: String,
        durationMinutes: Int,
        locationID: String?,
        posture: String?,
        items: [GroundworkRoutineSnapshotItem],
        warnings: [GroundworkWarning]
    ) {
        self.schemaVersion = schemaVersion
        self.routineID = routineID
        self.title = title
        self.durationMinutes = durationMinutes
        self.locationID = locationID
        self.posture = posture
        self.items = items
        self.warnings = warnings
    }

    func validate(provenance: GroundworkProvenance) throws {
        guard schemaVersion == GroundworkSchema.version else {
            throw GroundworkModelError.unsupportedSchema(schemaVersion)
        }
        try requireNonempty([title], label: "routine snapshot")
        guard (1...30).contains(durationMinutes), !items.isEmpty,
              Set(items.map(\.itemID)).count == items.count else {
            throw GroundworkModelError.invalid("routine snapshot duration/items are invalid")
        }
        for item in items {
            try requireNonempty([item.itemID, item.name], label: "routine snapshot item")
            guard item.cues.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw GroundworkModelError.invalid("routine snapshot contains an empty cue")
            }
            try item.plannedDose?.validate()
            try item.warnings.forEach { try $0.validate() }
            if provenance != .local {
                guard let routineID, !routineID.isEmpty,
                      let locationID, !locationID.isEmpty,
                      let posture, !posture.isEmpty,
                      item.exerciseID?.isEmpty == false,
                      item.prescriptionID?.isEmpty == false,
                      item.plannedDose != nil else {
                    throw GroundworkModelError.invalid("generated snapshot is missing canonical mapping")
                }
            }
        }
        try warnings.forEach { try $0.validate() }
    }
}

struct GroundworkActualDose: Codable, Equatable {
    let sets: Int?
    let reps: Int?
    let holdSeconds: Int?
    let side: String?

    enum CodingKeys: String, CodingKey { case sets, reps, holdSeconds, side }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // The wire contract distinguishes an unobserved measurement from a missing field.
        try container.encode(sets, forKey: .sets)
        try container.encode(reps, forKey: .reps)
        try container.encode(holdSeconds, forKey: .holdSeconds)
        try container.encode(side, forKey: .side)
    }

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
    let routineSnapshot: GroundworkRoutineSnapshot
    let checkedItemIDs: [String]
    let completedItems: [GroundworkCompletedItem]
    let warningOverrides: [GroundworkWarningOverride]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case clientSessionID = "clientSessionId"
        case startedAt, finishedAt, provenance, routineSnapshot
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
        try routineSnapshot.validate(provenance: provenance)
        let itemIDs = Set(routineSnapshot.items.map(\.itemID))
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
