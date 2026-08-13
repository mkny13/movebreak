import Foundation

/// A routine is just a named slice of the exercise catalog — the actual catalog picks
/// live in `RoutineStore`; this struct is the ready-to-display result of resolving one.
struct Routine: Identifiable {
    let id = UUID()
    let key: String              // matches the owning SavedRoutine.id
    let title: String
    let subtitle: String
    let estimatedMinutes: Int
    let exercises: [Exercise]

    /// Semi-randomized order for a session: walk-safe exercises are shuffled among
    /// themselves and shown first, pause-treadmill exercises are shuffled among
    /// themselves and shown after. This keeps the one deliberate constraint — don't make
    /// someone stop the treadmill before they've done the work that doesn't require it —
    /// while still varying the order (and, via `RoutineWindow`'s area grouping, which
    /// area shows up first) from one session to the next.
    func shuffledForSession() -> Routine {
        let walkSafe = exercises.filter { $0.treadmill == .walkSafe }.shuffled()
        let pause = exercises.filter { $0.treadmill == .pauseTreadmill }.shuffled()
        return Routine(
            key: key, title: title, subtitle: subtitle,
            estimatedMinutes: estimatedMinutes, exercises: walkSafe + pause
        )
    }
}

enum Routines {
    static let disclaimer =
        "General movement prompts, not medical advice — stop anything that increases pain, "
        + "and defer to your PT."
}
