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
    }
}
