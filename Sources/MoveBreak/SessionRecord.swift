import Foundation

/// A completed routine, captured when the user clicks Done on the checklist.
struct SessionRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let routineKey: String
    let routineTitle: String
    let exercisesCompleted: [String]
    let completedCount: Int
    let totalCount: Int
    let estimatedMinutes: Int
    /// Present for completions created after Groundwork sync shipped. Keeping these fields
    /// optional preserves decoding of every legacy sessions.jsonl line.
    let groundworkCompletion: GroundworkCompletionRequest?
    let groundworkDestination: GroundworkOrigin?

    init(routine: Routine, checkedIDs: Set<String>, date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.routineKey = routine.key
        self.routineTitle = routine.title
        self.exercisesCompleted = routine.exercises
            .filter { checkedIDs.contains($0.id) }
            .map(\.name)
        self.completedCount = exercisesCompleted.count
        self.totalCount = routine.exercises.count
        self.estimatedMinutes = routine.estimatedMinutes
        self.groundworkCompletion = nil
        self.groundworkDestination = nil
    }

    init(completion: RoutineCompletion, destination: GroundworkOrigin?) {
        let request = completion.request
        self.id = request.clientSessionID
        self.date = request.finishedAt
        self.routineKey = completion.routine.key
        self.routineTitle = completion.routine.title
        self.exercisesCompleted = completion.routine.exercises
            .filter { request.checkedItemIDs.contains($0.id) }
            .map(\.name)
        self.completedCount = request.checkedItemIDs.count
        self.totalCount = completion.routine.exercises.count
        self.estimatedMinutes = completion.routine.estimatedMinutes
        self.groundworkCompletion = request
        self.groundworkDestination = destination
    }
}
