import Foundation

struct RoutineCompletion {
    let routine: Routine
    let clientSessionID: UUID
    let startedAt: Date
    let finishedAt: Date
    let checkedItemIDs: [String]
    let completedItems: [GroundworkCompletedItem]
    let warningOverrides: [GroundworkWarningOverride]

    var request: GroundworkCompletionRequest {
        GroundworkCompletionRequest(
            schemaVersion: GroundworkSchema.version,
            clientSessionID: clientSessionID,
            startedAt: startedAt,
            finishedAt: finishedAt,
            provenance: routine.provenance,
            routineSnapshot: routine.completionSnapshot,
            checkedItemIDs: checkedItemIDs,
            completedItems: completedItems,
            warningOverrides: warningOverrides
        )
    }
}

/// Owns per-run identity/timestamps and makes Done idempotent even if the UI action fires twice.
final class RoutineSessionTracker {
    let routine: Routine
    let clientSessionID: UUID
    let startedAt: Date
    private var didFinish = false

    init(routine: Routine, clientSessionID: UUID = UUID(), startedAt: Date = Date()) {
        self.routine = routine
        self.clientSessionID = clientSessionID
        self.startedAt = startedAt
    }

    func requiredWarningIDs(checkedIDs: Set<String>) -> [String] {
        guard !checkedIDs.isEmpty else { return [] }
        let routineWarnings = routine.generatedRoutine?.warnings ?? []
        let itemWarnings = routine.exercises
            .filter { checkedIDs.contains($0.id) }
            .flatMap { $0.generated?.warnings ?? [] }
        var seen: Set<String> = []
        return (routineWarnings + itemWarnings).compactMap { warning in
            seen.insert(warning.ruleID).inserted ? warning.ruleID : nil
        }
    }

    func finish(
        checkedIDs: Set<String>,
        actualDoses: [String: GroundworkActualDose],
        warningReasons: [String: String],
        finishedAt: Date = Date()
    ) -> RoutineCompletion? {
        guard !didFinish else { return nil }
        let requiredWarnings = requiredWarningIDs(checkedIDs: checkedIDs)
        guard requiredWarnings.allSatisfy({ warningReasons[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else {
            return nil
        }

        let checkedInOrder = routine.exercises.filter { checkedIDs.contains($0.id) }
        let completed = checkedInOrder.map { exercise in
            GroundworkCompletedItem(
                itemID: exercise.id,
                actualDose: actualDoses[exercise.id] ?? confirmedPlannedDose(for: exercise)
            )
        }
        let overrides = requiredWarnings.compactMap { ruleID -> GroundworkWarningOverride? in
            guard let reason = warningReasons[ruleID]?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
                return nil
            }
            return GroundworkWarningOverride(ruleID: ruleID, reason: reason)
        }
        didFinish = true
        return RoutineCompletion(
            routine: routine,
            clientSessionID: clientSessionID,
            startedAt: startedAt,
            finishedAt: finishedAt,
            checkedItemIDs: checkedInOrder.map(\.id),
            completedItems: completed,
            warningOverrides: overrides
        )
    }

    private func confirmedPlannedDose(for exercise: Exercise) -> GroundworkActualDose {
        guard let planned = exercise.generated?.plannedDose else {
            return GroundworkActualDose(sets: nil, reps: nil, holdSeconds: nil, side: nil)
        }
        return GroundworkActualDose(
            sets: planned.sets,
            reps: planned.reps,
            holdSeconds: planned.holdSeconds,
            side: planned.side
        )
    }
}
