import Foundation

/// Whether an exercise can be done with the belt running.
enum TreadmillTag: String {
    case walkSafe        // upper body, jaw, neck — fine while walking
    case pauseTreadmill  // needs balance, the floor, or a foot off the belt

    var badge: String {
        switch self {
        case .walkSafe:       return "🚶"
        case .pauseTreadmill: return "⏸"
        }
    }

    var help: String {
        switch self {
        case .walkSafe:       return "Can do while the treadmill is running"
        case .pauseTreadmill: return "Pause the treadmill for this one"
        }
    }
}

/// Which desk posture an exercise is written for.
///
/// MVP only populates `.standing` (treadmill desk). The field exists now so adding a
/// "Sitting at Desk" mode later is a content change, not a refactor.
enum Posture: String {
    case standing
    case seated
}

struct Exercise: Identifiable {
    let id = UUID()
    let name: String
    let dose: String            // "30s per side", "12 reps"
    let cue: String             // one line of form guidance
    let treadmill: TreadmillTag
    let posture: Posture
    let area: String            // grouping label, e.g. "Sciatic"

    init(
        _ name: String,
        dose: String,
        cue: String,
        treadmill: TreadmillTag,
        posture: Posture = .standing,
        area: String
    ) {
        self.name = name
        self.dose = dose
        self.cue = cue
        self.treadmill = treadmill
        self.posture = posture
        self.area = area
    }
}

struct Routine: Identifiable {
    let id = UUID()
    let key: String
    let title: String
    let subtitle: String
    let estimatedMinutes: Int
    let exercises: [Exercise]
}

enum Routines {

    static let all: [Routine] = [physicalTherapy, workout, justStretch]

    static func routine(key: String) -> Routine? {
        all.first { $0.key == key }
    }

    /// Targets the four specific problem areas: sciatic, jaw/TMJ, trap/levator, plantar
    /// fascia. Ordered so the walk-safe upper-body work comes first — if you only get
    /// halfway through, you've done the part that needs no treadmill pause.
    static let physicalTherapy = Routine(
        key: "pt",
        title: "Do PT",
        subtitle: "Sciatic · jaw · traps · plantar fascia",
        estimatedMinutes: 8,
        exercises: [
            // Jaw / TMJ — all fine while walking
            Exercise(
                "Tongue-to-palate opening",
                dose: "6 slow reps",
                cue: "Tongue tip on the roof of your mouth, open only as far as it stays there.",
                treadmill: .walkSafe, area: "Jaw / TMJ"
            ),
            Exercise(
                "Masseter + temporalis massage",
                dose: "45 sec",
                cue: "Small circles on the jaw corner and the temple. Ease off if it's sharp.",
                treadmill: .walkSafe, area: "Jaw / TMJ"
            ),
            Exercise(
                "Chin tucks",
                dose: "10 reps, 3 sec hold",
                cue: "Draw the chin straight back, long neck. No nodding down.",
                treadmill: .walkSafe, area: "Jaw / TMJ"
            ),

            // Trap / levator — also walk-safe
            Exercise(
                "Upper trap stretch",
                dose: "30 sec per side",
                cue: "Ear toward shoulder, other hand reaching down. Shoulder stays low.",
                treadmill: .walkSafe, area: "Traps / neck"
            ),
            Exercise(
                "Levator scap stretch",
                dose: "30 sec per side",
                cue: "Turn your nose toward your armpit, then let the head drop.",
                treadmill: .walkSafe, area: "Traps / neck"
            ),
            Exercise(
                "Scapular retractions",
                dose: "10 reps, 3 sec hold",
                cue: "Squeeze the shoulder blades back and down, not up toward the ears.",
                treadmill: .walkSafe, area: "Traps / neck"
            ),

            // Sciatic — needs the belt stopped
            Exercise(
                "Standing figure-4",
                dose: "30 sec per side",
                cue: "Ankle across the opposite knee, hold the desk, sit the hips back.",
                treadmill: .pauseTreadmill, area: "Sciatic"
            ),
            Exercise(
                "Sciatic nerve floss",
                dose: "10 reps per side",
                cue: "Extend the knee and point the toes as you tuck the chin; reverse together. Gentle — this should never be sharp.",
                treadmill: .pauseTreadmill, area: "Sciatic"
            ),
            Exercise(
                "Standing hamstring stretch",
                dose: "30 sec per side",
                cue: "Heel on the floor, toes up, hinge from the hip with a flat back.",
                treadmill: .pauseTreadmill, area: "Sciatic"
            ),

            // Plantar fascia — needs a foot off the belt
            Exercise(
                "Plantar fascia toe stretch",
                dose: "30 sec per side",
                cue: "Pull the toes back toward the shin until the arch tightens.",
                treadmill: .pauseTreadmill, area: "Plantar fascia"
            ),
            Exercise(
                "Ball roll under the arch",
                dose: "60 sec per side",
                cue: "Slow passes heel to ball of foot. Firm pressure, not painful.",
                treadmill: .pauseTreadmill, area: "Plantar fascia"
            ),
            Exercise(
                "Calf stretch — straight then bent knee",
                dose: "30 sec each, per side",
                cue: "Straight knee hits the gastroc, bent knee hits the soleus. Do both.",
                treadmill: .pauseTreadmill, area: "Plantar fascia"
            ),
        ]
    )

    static let workout = Routine(
        key: "workout",
        title: "Workout",
        subtitle: "Bodyweight strength at the desk",
        estimatedMinutes: 10,
        exercises: [
            Exercise(
                "Incline desk push-ups",
                dose: "12 reps",
                cue: "Hands on a stable edge, body in one line, elbows about 45°.",
                treadmill: .pauseTreadmill, area: "Push"
            ),
            Exercise(
                "Bodyweight squats",
                dose: "15 reps",
                cue: "Weight through the midfoot, knees tracking over the toes.",
                treadmill: .pauseTreadmill, area: "Legs"
            ),
            Exercise(
                "Reverse lunges",
                dose: "10 per side",
                cue: "Step back, drop the back knee straight down. Hold the desk if needed.",
                treadmill: .pauseTreadmill, area: "Legs"
            ),
            Exercise(
                "Calf raises",
                dose: "20 reps",
                cue: "Slow up, slower down. Doubles as plantar fascia loading.",
                treadmill: .pauseTreadmill, area: "Legs"
            ),
            Exercise(
                "Glute bridges",
                dose: "15 reps",
                cue: "Drive through the heels, squeeze at the top, ribs down.",
                treadmill: .pauseTreadmill, area: "Posterior chain"
            ),
            Exercise(
                "Dead bug",
                dose: "10 per side",
                cue: "Low back stays flat on the floor the whole time.",
                treadmill: .pauseTreadmill, area: "Core"
            ),
            Exercise(
                "Wall sit",
                dose: "45 sec",
                cue: "Thighs toward parallel, back flat to the wall, breathe.",
                treadmill: .pauseTreadmill, area: "Legs"
            ),
        ]
    )

    /// Deliberately mostly walk-safe — this is the one to pick when you don't want to
    /// stop walking or be obvious on camera.
    static let justStretch = Routine(
        key: "stretch",
        title: "Just Stretch",
        subtitle: "Quick and mostly walk-safe",
        estimatedMinutes: 4,
        exercises: [
            Exercise(
                "Shoulder rolls",
                dose: "10 back, 10 forward",
                cue: "Big slow circles. Let the shoulder blades move.",
                treadmill: .walkSafe, area: "Upper body"
            ),
            Exercise(
                "Neck half-circles",
                dose: "5 each direction",
                cue: "Ear to chest to ear. Skip the backward half.",
                treadmill: .walkSafe, area: "Neck"
            ),
            Exercise(
                "Desk-edge pec stretch",
                dose: "30 sec per side",
                cue: "Forearm on the door frame or desk edge, rotate the chest away.",
                treadmill: .walkSafe, area: "Chest"
            ),
            Exercise(
                "Thoracic extension",
                dose: "5 slow reps",
                cue: "Hands behind the head, open the upper back. Don't arch the low back.",
                treadmill: .walkSafe, area: "Upper back"
            ),
            Exercise(
                "Standing side bend",
                dose: "20 sec per side",
                cue: "Reach one arm overhead and lean. Hips stay square.",
                treadmill: .walkSafe, area: "Side body"
            ),
            Exercise(
                "Forearm + wrist stretch",
                dose: "20 sec per side",
                cue: "Arm straight, fingers back then down. Both directions.",
                treadmill: .walkSafe, area: "Forearms"
            ),
            Exercise(
                "Standing quad stretch",
                dose: "30 sec per side",
                cue: "Heel to glute, knees together, hold the desk for balance.",
                treadmill: .pauseTreadmill, area: "Legs"
            ),
            Exercise(
                "Ankle circles",
                dose: "10 each direction, per side",
                cue: "Big slow circles from the ankle, not the whole leg.",
                treadmill: .pauseTreadmill, area: "Ankles / feet"
            ),
        ]
    )

    static let disclaimer =
        "General movement prompts, not medical advice — stop anything that increases pain, "
        + "and defer to your PT."
}
