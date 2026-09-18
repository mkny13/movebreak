import Foundation

/// A routine is just a named slice of the exercise catalog — the actual catalog picks
/// live in `RoutineStore`; this struct is the ready-to-display result of resolving one.
struct Routine: Identifiable {
    let id: UUID
    let key: String              // matches the owning SavedRoutine.id
    let title: String
    let subtitle: String
    let estimatedMinutes: Int
    let exercises: [Exercise]
    let provenance: GroundworkProvenance
    let sourceLabel: String?
    let generatedRoutine: GroundworkRoutine?

    init(
        id: UUID = UUID(),
        key: String,
        title: String,
        subtitle: String,
        estimatedMinutes: Int,
        exercises: [Exercise],
        provenance: GroundworkProvenance = .local,
        sourceLabel: String? = nil,
        generatedRoutine: GroundworkRoutine? = nil
    ) {
        self.id = id
        self.key = key
        self.title = title
        self.subtitle = subtitle
        self.estimatedMinutes = estimatedMinutes
        self.exercises = exercises
        self.provenance = provenance
        self.sourceLabel = sourceLabel
        self.generatedRoutine = generatedRoutine
    }

    init(generated: GroundworkRoutine, provenance: GroundworkProvenance, sourceLabel: String) {
        self.init(
            key: generated.id,
            title: generated.title,
            subtitle: "Groundwork · \(generated.posture)",
            estimatedMinutes: generated.durationMinutes,
            exercises: generated.items.map(Exercise.init(item:)),
            provenance: provenance,
            sourceLabel: sourceLabel,
            generatedRoutine: generated
        )
    }

    var isGenerated: Bool { generatedRoutine != nil }

    /// Semi-randomized order for a session: walk-safe exercises are shuffled among
    /// themselves and shown first, pause-treadmill exercises are shuffled among
    /// themselves and shown after. This keeps the one deliberate constraint — don't make
    /// someone stop the treadmill before they've done the work that doesn't require it —
    /// while still varying the order (and, via `RoutineWindow`'s area grouping, which
    /// area shows up first) from one session to the next.
    func shuffledForSession() -> Routine {
        guard !isGenerated else { return self }
        let walkSafe = exercises.filter { $0.treadmill == .walkSafe }.shuffled()
        let pause = exercises.filter { $0.treadmill == .pauseTreadmill }.shuffled()
        return Routine(
            key: key, title: title, subtitle: subtitle,
            estimatedMinutes: estimatedMinutes, exercises: walkSafe + pause,
            provenance: provenance, sourceLabel: sourceLabel
        )
    }


    var completionSnapshot: GroundworkRoutineSnapshot {
        if let generatedRoutine { return GroundworkRoutineSnapshot(routine: generatedRoutine) }
        return GroundworkRoutineSnapshot(
            routineID: nil,
            title: title,
            durationMinutes: estimatedMinutes,
            locationID: nil,
            posture: nil,
            items: exercises.map {
                GroundworkRoutineSnapshotItem(
                    itemID: $0.id,
                    exerciseID: nil,
                    prescriptionID: nil,
                    name: $0.name,
                    cues: [$0.cue],
                    plannedDose: nil,
                    warnings: []
                )
            },
            warnings: []
        )
    }
}

enum Routines {
    static let disclaimer =
        "General movement prompts, not medical advice — stop anything that increases pain, "
        + "and defer to your PT."
}
