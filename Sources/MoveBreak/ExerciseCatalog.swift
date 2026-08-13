import Foundation

/// Whether an exercise can be done with the belt running.
enum TreadmillTag: String, Codable {
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
enum Posture: String, Codable {
    case standing
    case seated
}

struct Exercise: Identifiable, Codable {
    /// Stable across launches (a slug of the name), unlike a UUID — routines persisted in
    /// UserDefaults reference exercises by this id, so it has to survive a relaunch.
    let id: String
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
        self.id = Exercise.slug(name)
        self.name = name
        self.dose = dose
        self.cue = cue
        self.treadmill = treadmill
        self.posture = posture
        self.area = area
    }

    static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            (CharacterSet.alphanumerics.contains(scalar)) ? Character(scalar) : "-"
        }
        var result = String(mapped)
        while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// The full library of exercises a custom routine can be built from. Grouped here by area
/// only for readability — the routine builder groups the same way when presenting them.
enum ExerciseCatalog {

    static let all: [Exercise] = jawAndTMJ + trapsAndNeck + sciatic + plantarFascia
        + push + legs + posteriorChain + core + upperBody + neck + chest + upperBack
        + sideBody + forearms + ankles + shoulders + scapularStabilization + hips + spine

    // MARK: - Jaw / TMJ — all fine while walking

    static let jawAndTMJ: [Exercise] = [
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
    ]

    // MARK: - Traps / neck — also walk-safe

    static let trapsAndNeck: [Exercise] = [
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
    ]

    // MARK: - Sciatic — needs the belt stopped

    static let sciatic: [Exercise] = [
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
    ]

    // MARK: - Plantar fascia — needs a foot off the belt

    static let plantarFascia: [Exercise] = [
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

    // MARK: - Push

    static let push: [Exercise] = [
        Exercise(
            "Incline desk push-ups",
            dose: "12 reps",
            cue: "Hands on a stable edge, body in one line, elbows about 45°.",
            treadmill: .pauseTreadmill, area: "Push"
        ),
        Exercise(
            "Wall push-ups",
            dose: "12 reps",
            cue: "Hands on the wall at shoulder height, lean in and push back out, body stays in one line.",
            treadmill: .pauseTreadmill, area: "Push"
        ),
        Exercise(
            "Isometric push-up hold",
            dose: "20 sec hold",
            cue: "Hold halfway down in a push-up, elbows about 45°, ribs pulled down.",
            treadmill: .pauseTreadmill, area: "Push"
        ),
        Exercise(
            "Desk-edge triceps dips",
            dose: "10 reps",
            cue: "Hands on the desk edge behind you, bend the elbows straight back, don't let the shoulders creep up.",
            treadmill: .pauseTreadmill, area: "Push"
        ),
    ]

    // MARK: - Legs

    static let legs: [Exercise] = [
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
            "Wall sit",
            dose: "45 sec",
            cue: "Thighs toward parallel, back flat to the wall, breathe.",
            treadmill: .pauseTreadmill, area: "Legs"
        ),
        Exercise(
            "Standing quad stretch",
            dose: "30 sec per side",
            cue: "Heel to glute, knees together, hold the desk for balance.",
            treadmill: .pauseTreadmill, area: "Legs"
        ),
        Exercise(
            "Isometric split squat hold",
            dose: "20 sec per side",
            cue: "Staggered stance, back knee hovering just off the floor, front shin vertical, hold the desk for balance.",
            treadmill: .pauseTreadmill, area: "Legs"
        ),
        Exercise(
            "Single-leg calf raise",
            dose: "10 per side",
            cue: "All the weight on one foot, rise slow, lower slower. Hold the desk lightly for balance.",
            treadmill: .pauseTreadmill, area: "Legs"
        ),
        Exercise(
            "Standing terminal knee extension",
            dose: "12 per side",
            cue: "Start with a slight knee bend, squeeze the quad to straighten it fully without locking out hard.",
            treadmill: .pauseTreadmill, area: "Legs"
        ),
        Exercise(
            "Curtsy lunge",
            dose: "10 per side",
            cue: "Step one leg diagonally behind the other, both knees bend, chest stays tall. Hold the desk if needed.",
            treadmill: .pauseTreadmill, area: "Legs"
        ),
    ]

    // MARK: - Posterior chain

    static let posteriorChain: [Exercise] = [
        Exercise(
            "Glute bridges",
            dose: "15 reps",
            cue: "Drive through the heels, squeeze at the top, ribs down.",
            treadmill: .pauseTreadmill, area: "Posterior chain"
        ),
        Exercise(
            "Glute bridge hold",
            dose: "30 sec hold",
            cue: "Hips lifted and squeezed at the top, ribs down, hold without arching the low back.",
            treadmill: .pauseTreadmill, area: "Posterior chain"
        ),
        Exercise(
            "Single-leg glute bridge",
            dose: "10 per side",
            cue: "One foot planted, other leg extended straight, drive through the planted heel without rocking the hips.",
            treadmill: .pauseTreadmill, area: "Posterior chain"
        ),
        Exercise(
            "Standing hamstring curl",
            dose: "12 per side",
            cue: "Hold the desk, curl the heel toward the glute, control the way down.",
            treadmill: .pauseTreadmill, area: "Posterior chain"
        ),
    ]

    // MARK: - Core

    static let core: [Exercise] = [
        Exercise(
            "Dead bug",
            dose: "10 per side",
            cue: "Low back stays flat on the floor the whole time.",
            treadmill: .pauseTreadmill, area: "Core"
        ),
        Exercise(
            "Plank hold",
            dose: "30 sec hold",
            cue: "Forearms and toes down, straight line from head to heels, ribs pulled down.",
            treadmill: .pauseTreadmill, area: "Core"
        ),
        Exercise(
            "Side plank hold",
            dose: "20 sec per side",
            cue: "Stack the feet, hips lifted into a straight line, top hand on the hip or reaching up.",
            treadmill: .pauseTreadmill, area: "Core"
        ),
        Exercise(
            "Bird dog hold",
            dose: "15 sec per side",
            cue: "Opposite arm and leg extended, hips level, low back stays neutral — no arching.",
            treadmill: .pauseTreadmill, area: "Core"
        ),
        Exercise(
            "Standing abdominal brace",
            dose: "20 sec x3",
            cue: "Gently tighten the abs as if bracing for a light punch, breathe normally, keep walking.",
            treadmill: .walkSafe, area: "Core"
        ),
    ]

    // MARK: - Upper body

    static let upperBody: [Exercise] = [
        Exercise(
            "Shoulder rolls",
            dose: "10 back, 10 forward",
            cue: "Big slow circles. Let the shoulder blades move.",
            treadmill: .walkSafe, area: "Upper body"
        ),
    ]

    // MARK: - Neck

    static let neck: [Exercise] = [
        Exercise(
            "Neck half-circles",
            dose: "5 each direction",
            cue: "Ear to chest to ear. Skip the backward half.",
            treadmill: .walkSafe, area: "Neck"
        ),
        Exercise(
            "Neck side bend",
            dose: "20 sec per side",
            cue: "Ear toward shoulder without lifting the shoulder. Gentle overpressure with the hand only if pain-free.",
            treadmill: .walkSafe, area: "Neck"
        ),
        Exercise(
            "Isometric neck resistance hold",
            dose: "10 sec x4 directions",
            cue: "Press your head into your own hand — forward, back, each side — without letting the head actually move.",
            treadmill: .walkSafe, area: "Neck"
        ),
    ]

    // MARK: - Chest

    static let chest: [Exercise] = [
        Exercise(
            "Desk-edge pec stretch",
            dose: "30 sec per side",
            cue: "Forearm on the door frame or desk edge, rotate the chest away.",
            treadmill: .walkSafe, area: "Chest"
        ),
        Exercise(
            "Isometric chest press",
            dose: "20 sec x3",
            cue: "Palms together at chest height, push into each other without letting the hands slide.",
            treadmill: .walkSafe, area: "Chest"
        ),
    ]

    // MARK: - Upper back

    static let upperBack: [Exercise] = [
        Exercise(
            "Thoracic extension",
            dose: "5 slow reps",
            cue: "Hands behind the head, open the upper back. Don't arch the low back.",
            treadmill: .walkSafe, area: "Upper back"
        ),
    ]

    // MARK: - Side body

    static let sideBody: [Exercise] = [
        Exercise(
            "Standing side bend",
            dose: "20 sec per side",
            cue: "Reach one arm overhead and lean. Hips stay square.",
            treadmill: .walkSafe, area: "Side body"
        ),
    ]

    // MARK: - Forearms

    static let forearms: [Exercise] = [
        Exercise(
            "Forearm + wrist stretch",
            dose: "20 sec per side",
            cue: "Arm straight, fingers back then down. Both directions.",
            treadmill: .walkSafe, area: "Forearms"
        ),
        Exercise(
            "Prayer stretch",
            dose: "20 sec",
            cue: "Palms together at chest height, lower the hands while keeping palms together until you feel a stretch.",
            treadmill: .walkSafe, area: "Forearms"
        ),
        Exercise(
            "Wrist circles",
            dose: "10 each direction",
            cue: "Loose fists, big slow circles from the wrist only.",
            treadmill: .walkSafe, area: "Forearms"
        ),
    ]

    // MARK: - Ankles / feet

    static let ankles: [Exercise] = [
        Exercise(
            "Ankle circles",
            dose: "10 each direction, per side",
            cue: "Big slow circles from the ankle, not the whole leg.",
            treadmill: .pauseTreadmill, area: "Ankles / feet"
        ),
        Exercise(
            "Single-leg balance hold",
            dose: "20 sec per side",
            cue: "Stand on one foot, soft knee, find a still point to look at. Hold the desk if you need to.",
            treadmill: .pauseTreadmill, area: "Ankles / feet"
        ),
        Exercise(
            "Ankle dorsiflexion rock",
            dose: "10 per side",
            cue: "Foot flat, drive the knee forward over the toes without the heel lifting.",
            treadmill: .pauseTreadmill, area: "Ankles / feet"
        ),
        Exercise(
            "Toe raises",
            dose: "15 reps",
            cue: "Rock back onto the heels and lift the toes and forefoot, then lower with control.",
            treadmill: .pauseTreadmill, area: "Ankles / feet"
        ),
    ]

    // MARK: - Shoulders

    static let shoulders: [Exercise] = [
        Exercise(
            "Standing arm circles",
            dose: "10 each direction, per arm",
            cue: "Big slow circles, small to large. Reverse direction halfway through.",
            treadmill: .walkSafe, area: "Shoulders"
        ),
        Exercise(
            "Shoulder external rotation isometric",
            dose: "20 sec per side",
            cue: "Elbow at your side bent 90°, press the back of your hand outward into your other hand without moving the elbow.",
            treadmill: .walkSafe, area: "Shoulders"
        ),
        Exercise(
            "Cross-body shoulder stretch",
            dose: "30 sec per side",
            cue: "Pull one arm across your chest with the other forearm, shoulder relaxed away from the ear.",
            treadmill: .walkSafe, area: "Shoulders"
        ),
        Exercise(
            "Overhead triceps stretch",
            dose: "30 sec per side",
            cue: "Elbow up and back, opposite hand gently presses it down. Ribs stay down, no arching.",
            treadmill: .walkSafe, area: "Shoulders"
        ),
        Exercise(
            "Doorway shoulder stretch",
            dose: "30 sec per side",
            cue: "Forearm on the door frame, arm at shoulder height, lean gently through the doorway.",
            treadmill: .pauseTreadmill, area: "Shoulders"
        ),
    ]

    // MARK: - Scapular stabilization — evidence-based rehab staples for shoulder/upper-back health

    static let scapularStabilization: [Exercise] = [
        Exercise(
            "Standing bent-over Y raise",
            dose: "10 reps",
            cue: "Hinge from the hips with a flat back, lift the arms overhead in a Y, thumbs up.",
            treadmill: .pauseTreadmill, area: "Scapular stabilization"
        ),
        Exercise(
            "Standing bent-over T raise",
            dose: "10 reps",
            cue: "Same hinge, lift the arms straight out to a T, squeeze the shoulder blades together.",
            treadmill: .pauseTreadmill, area: "Scapular stabilization"
        ),
        Exercise(
            "Standing bent-over W raise",
            dose: "10 reps",
            cue: "Elbows bent and pulled back like drawing a bow, squeeze the shoulder blades down and in.",
            treadmill: .pauseTreadmill, area: "Scapular stabilization"
        ),
    ]

    // MARK: - Hips

    static let hips: [Exercise] = [
        Exercise(
            "Standing hip abduction",
            dose: "12 per side",
            cue: "Hold the desk, lift the leg straight out to the side, hips stay level — don't lean.",
            treadmill: .pauseTreadmill, area: "Hips"
        ),
        Exercise(
            "Standing hip flexor stretch",
            dose: "30 sec per side",
            cue: "Split stance, back knee soft, tuck the pelvis under and shift the weight forward.",
            treadmill: .pauseTreadmill, area: "Hips"
        ),
        Exercise(
            "Standing IT band stretch",
            dose: "20 sec per side",
            cue: "Cross one foot behind the other, lean away from that side, feel it along the outer hip.",
            treadmill: .pauseTreadmill, area: "Hips"
        ),
        Exercise(
            "Fire hydrant",
            dose: "10 per side",
            cue: "On hands and knees, lift one knee out to the side keeping the hip stable, low back still.",
            treadmill: .pauseTreadmill, area: "Hips"
        ),
        Exercise(
            "90/90 hip stretch",
            dose: "30 sec per side",
            cue: "Seated on the floor, both knees bent 90°, hinge forward over the front shin.",
            treadmill: .pauseTreadmill, area: "Hips"
        ),
    ]

    // MARK: - Spine

    static let spine: [Exercise] = [
        Exercise(
            "Standing pelvic tilts",
            dose: "10 reps",
            cue: "Gently rock the pelvis forward and back, small movement, the low back does the work.",
            treadmill: .walkSafe, area: "Spine"
        ),
        Exercise(
            "Standing spinal rotation",
            dose: "10 per side",
            cue: "Arms loose, rotate the torso side to side, let the head follow, hips stay facing forward.",
            treadmill: .walkSafe, area: "Spine"
        ),
        Exercise(
            "Standing forward fold",
            dose: "30 sec",
            cue: "Hinge from the hips, soft knees, let the head and arms hang heavy.",
            treadmill: .pauseTreadmill, area: "Spine"
        ),
    ]

    static func exercise(id: String) -> Exercise? {
        all.first { $0.id == id }
    }

    /// The catalog grouped by area, in the same first-appearance order as `all` — the
    /// order these eighteen `MARK:` sections are declared above.
    static var groupedByArea: [(area: String, exercises: [Exercise])] {
        var order: [String] = []
        var buckets: [String: [Exercise]] = [:]
        for exercise in all {
            if buckets[exercise.area] == nil {
                order.append(exercise.area)
                buckets[exercise.area] = []
            }
            buckets[exercise.area]?.append(exercise)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}
