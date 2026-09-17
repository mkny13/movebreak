import Foundation

/// A user-defined routine: a name plus a set of catalog exercise ids. This is the
/// persisted form — `RoutineStore.routine(for:)` resolves it against `ExerciseCatalog`
/// into a displayable `Routine` with a subtitle and time estimate.
struct SavedRoutine: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var exerciseIDs: [String]
}

/// Owns the user's saved routines: persistence (UserDefaults, JSON-encoded), the catalog
/// picker's add/rename/delete/toggle operations, and resolving a `SavedRoutine` into a
/// displayable `Routine`.
final class RoutineStore: ObservableObject {
    static let shared = RoutineStore()

    @Published private(set) var routines: [SavedRoutine] {
        didSet { persist() }
    }

    private static let defaultsKey = "savedRoutines"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        routines = RoutineStore.load(from: defaults) ?? RoutineStore.defaultSeeds
    }

    // MARK: - CRUD

    @discardableResult
    func addRoutine(named name: String) -> SavedRoutine {
        let routine = SavedRoutine(id: UUID().uuidString, name: name, exerciseIDs: [])
        routines.append(routine)
        return routine
    }

    func rename(_ id: String, to name: String) {
        guard let index = routines.firstIndex(where: { $0.id == id }) else { return }
        routines[index].name = name
    }

    func delete(_ id: String) {
        routines.removeAll { $0.id == id }
    }

    func isExerciseIncluded(_ exerciseID: String, in routineID: String) -> Bool {
        routines.first { $0.id == routineID }?.exerciseIDs.contains(exerciseID) ?? false
    }

    func setExercise(_ exerciseID: String, included: Bool, in routineID: String) {
        guard let index = routines.firstIndex(where: { $0.id == routineID }) else { return }
        if included {
            if !routines[index].exerciseIDs.contains(exerciseID) {
                routines[index].exerciseIDs.append(exerciseID)
            }
        } else {
            routines[index].exerciseIDs.removeAll { $0 == exerciseID }
        }
    }

    // MARK: - Resolving

    /// All saved routines, resolved and ready to display. A routine with nothing picked
    /// yet is left out — an empty in-progress custom routine has no business showing up
    /// in the prompt popup or the menu bar.
    var resolvedRoutines: [Routine] {
        routines.compactMap(routine(for:))
    }

    func routine(for saved: SavedRoutine) -> Routine? {
        let exercises = saved.exerciseIDs.compactMap(ExerciseCatalog.exercise(id:))
        guard !exercises.isEmpty else { return nil }

        var areas: [String] = []
        for exercise in exercises where !areas.contains(exercise.area) {
            areas.append(exercise.area)
        }

        return Routine(
            key: saved.id,
            title: saved.name,
            subtitle: areas.joined(separator: " · "),
            estimatedMinutes: RoutineStore.estimatedMinutes(forExerciseCount: exercises.count),
            exercises: exercises
        )
    }

    /// Rough heuristic (~45s per exercise, including per-side ones) rather than a
    /// hand-authored number — the exercise set is now user-defined, so there's no fixed
    /// list to eyeball a time for. Shared with the builder UI's live preview.
    static func estimatedMinutes(forExerciseCount count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(1, Int((Double(count) * 45 / 60).rounded()))
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(routines) else { return }
        defaults.set(data, forKey: RoutineStore.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> [SavedRoutine]? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode([SavedRoutine].self, from: data)
    }

    // MARK: - Default seeds

    /// First-launch content: the same three routines MoveBreak shipped with before the
    /// catalog picker existed, expressed as catalog picks so they're just as editable as
    /// anything the user builds themselves. Ids are derived from the exercise names
    /// (rather than hand-typed slugs) so they can never drift from `ExerciseCatalog`.
    private static func ids(_ names: [String]) -> [String] { names.map(Exercise.slug) }

    static let defaultSeeds: [SavedRoutine] = [
        SavedRoutine(id: "pt", name: "Do PT", exerciseIDs: ids([
            "Tongue-to-palate opening", "Masseter + temporalis massage", "Chin tucks",
            "Upper trap stretch", "Levator scap stretch", "Scapular retractions",
            "Standing figure-4", "Sciatic nerve floss", "Standing hamstring stretch",
            "Plantar fascia toe stretch", "Ball roll under the arch",
            "Calf stretch — straight then bent knee",
        ])),
        SavedRoutine(id: "workout", name: "Workout", exerciseIDs: ids([
            "Incline desk push-ups", "Bodyweight squats", "Reverse lunges", "Calf raises",
            "Glute bridges", "Dead bug", "Wall sit",
        ])),
        SavedRoutine(id: "stretch", name: "Just Stretch", exerciseIDs: ids([
            "Shoulder rolls", "Neck half-circles", "Desk-edge pec stretch",
            "Thoracic extension", "Standing side bend", "Forearm + wrist stretch",
            "Standing quad stretch", "Ankle circles",
        ])),
    ]
}
