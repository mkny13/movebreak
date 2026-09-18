import AppKit
import SwiftUI

final class RoutineWindowController {
    private var panel: FloatingPanel?
    private var tracker: RoutineSessionTracker?
    private var pendingCompletion: RoutineCompletion?
    var onFinish: ((RoutineCompletion, @escaping (Result<Void, Error>) -> Void) -> Void)?

    func show(_ routine: Routine) {
        close()
        let tracker = RoutineSessionTracker(routine: routine)
        self.tracker = tracker
        pendingCompletion = nil
        let panel = FloatingPanel(size: NSSize(width: 430, height: 640), title: routine.title)
        panel.setContent(RoutineView(routine: routine) { [weak self] checked, doses, reasons, saved in
            guard let self else { return }
            if self.pendingCompletion == nil {
                self.pendingCompletion = tracker.finish(
                    checkedIDs: checked,
                    actualDoses: doses,
                    warningReasons: reasons
                )
            }
            guard let completion = self.pendingCompletion, let onFinish = self.onFinish else {
                saved(.failure(RoutineWindowError.persistenceUnavailable))
                return
            }
            onFinish(completion) { [weak self] result in
                onMain {
                    if case .success = result { self?.close() }
                    saved(result)
                }
            }
        })
        panel.present()
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
        tracker = nil
        pendingCompletion = nil
    }

    var isVisible: Bool { panel != nil }
}

private enum RoutineWindowError: Error, LocalizedError {
    case persistenceUnavailable
    var errorDescription: String? { "Completion could not be saved. Try again." }
}

private struct RoutineView: View {
    let routine: Routine
    let onDone: (
        Set<String>, [String: GroundworkActualDose], [String: String],
        @escaping (Result<Void, Error>) -> Void
    ) -> Void

    @State private var checked: Set<String> = []
    @State private var doseValues: [String: String] = [:]
    @State private var warningReasons: [String: String] = [:]
    @State private var isSaving = false
    @State private var saveError: String?

    private var grouped: [(area: String, exercises: [Exercise])] {
        if routine.isGenerated { return [("", routine.exercises)] }
        var order: [String] = []
        var buckets: [String: [Exercise]] = [:]
        for exercise in routine.exercises {
            if buckets[exercise.area] == nil {
                order.append(exercise.area)
                buckets[exercise.area] = []
            }
            buckets[exercise.area]?.append(exercise)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private var requiredWarnings: [GroundworkWarning] {
        guard !checked.isEmpty else { return [] }
        let routineWarnings = routine.generatedRoutine?.warnings ?? []
        let itemWarnings = routine.exercises
            .filter { checked.contains($0.id) }
            .flatMap { $0.generated?.warnings ?? [] }
        var seen: Set<String> = []
        return (routineWarnings + itemWarnings).filter { seen.insert($0.ruleID).inserted }
    }

    private var warningReasonsComplete: Bool {
        requiredWarnings.allSatisfy {
            warningReasons[$0.ruleID]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let warnings = routine.generatedRoutine?.warnings, !warnings.isEmpty {
                        warningSection(warnings)
                    }
                    ForEach(Array(grouped.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 5) {
                            if !group.area.isEmpty {
                                Text(group.area.uppercased())
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 14)
                            }
                            ForEach(group.exercises) { exercise in
                                ExerciseRow(
                                    exercise: exercise,
                                    isChecked: checked.contains(exercise.id),
                                    doseBinding: doseBinding,
                                    warningReasonBinding: warningReasonBinding
                                ) { toggle(exercise) }
                            }
                        }
                    }
                    Text(Routines.disclaimer)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .padding(.horizontal, 14).padding(.top, 4)
                }
                .padding(.vertical, 12)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(routine.title).font(.headline)
                Spacer()
                Text("\(checked.count)/\(routine.exercises.count)")
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text("\(routine.subtitle) · ~\(routine.estimatedMinutes) min")
                .font(.caption).foregroundStyle(.secondary)
            if let label = routine.sourceLabel {
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !warningReasonsComplete {
                Text("Enter a reason for each warning before finishing.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let saveError {
                Text(saveError).font(.caption2).foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Text("\(TreadmillTag.walkSafe.badge) keep walking")
                Text("\(TreadmillTag.pauseTreadmill.badge) pause belt")
                Spacer(minLength: 0)
                Button("Done") {
                    isSaving = true
                    saveError = nil
                    onDone(checked, actualDoses(), warningReasons) { result in
                        isSaving = false
                        if case .failure(let error) = result {
                            saveError = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!warningReasonsComplete || isSaving)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder
    private func warningSection(_ warnings: [GroundworkWarning]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(warnings, id: \.ruleID) { warning in
                WarningCard(warning: warning, reason: warningReasonBinding(warning.ruleID))
            }
        }
        .padding(.horizontal, 14)
    }

    private func toggle(_ exercise: Exercise) {
        if checked.contains(exercise.id) { checked.remove(exercise.id) }
        else { checked.insert(exercise.id) }
    }

    private func doseBinding(_ itemID: String, _ field: String) -> Binding<String> {
        let key = "\(itemID).\(field)"
        return Binding(get: { doseValues[key] ?? "" }, set: { doseValues[key] = $0 })
    }

    private func warningReasonBinding(_ ruleID: String) -> Binding<String> {
        Binding(get: { warningReasons[ruleID] ?? "" }, set: { warningReasons[ruleID] = $0 })
    }

    private func actualDoses() -> [String: GroundworkActualDose] {
        var result: [String: GroundworkActualDose] = [:]
        for exercise in routine.exercises where checked.contains(exercise.id) && exercise.generated != nil {
            let setText = doseValues["\(exercise.id).sets"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let repText = doseValues["\(exercise.id).reps"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let holdText = doseValues["\(exercise.id).hold"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let side = doseValues["\(exercise.id).side"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sets = Int(setText).flatMap { $0 >= 0 ? $0 : nil }
            let reps = Int(repText).flatMap { $0 >= 0 ? $0 : nil }
            let hold = Int(holdText).flatMap { $0 >= 0 ? $0 : nil }
            let hasDeviation = !setText.isEmpty || !repText.isEmpty || !holdText.isEmpty || !side.isEmpty
            if hasDeviation {
                result[exercise.id] = GroundworkActualDose(
                    sets: sets, reps: reps, holdSeconds: hold,
                    side: side.isEmpty ? nil : side
                )
            }
        }
        return result
    }
}

private struct ExerciseRow: View {
    let exercise: Exercise
    let isChecked: Bool
    let doseBinding: (String, String) -> Binding<String>
    let warningReasonBinding: (String) -> Binding<String>
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                        .font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(exercise.name).font(.system(size: 12, weight: .medium))
                            Text(exercise.treadmill.badge).font(.system(size: 10)).help(exercise.treadmill.help)
                        }
                        Text(exercise.dose).font(.caption2).foregroundStyle(.secondary)
                        if exercise.generated != nil {
                            Text(isChecked
                                ? "Confirmed: completed the displayed dose"
                                : "Check to confirm completion of the displayed dose")
                                .font(.caption2)
                                .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                        }
                        Text(exercise.cue).font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let reasons = exercise.generated?.inclusionReasons, !reasons.isEmpty {
                            Text("Why: \(reasons.joined(separator: " • "))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .opacity(isChecked ? 0.72 : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let context = exercise.generated {
                if !context.warnings.isEmpty {
                    ForEach(context.warnings, id: \.ruleID) { warning in
                        WarningCard(warning: warning, reason: warningReasonBinding(warning.ruleID))
                    }
                }
                if isChecked {
                    DoseEditor(itemID: exercise.id, planned: context.plannedDose, binding: doseBinding)
                }
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 14)
        .background(isChecked ? Color.accentColor.opacity(0.05) : Color.clear)
    }
}

private struct WarningCard: View {
    let warning: GroundworkWarning
    @Binding var reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            Text(warning.rationale).font(.caption2)
            Text("Source: \(warning.source)").font(.caption2).foregroundStyle(.secondary)
            TextField("Reason for proceeding (required if completed)", text: $reason)
                .textFieldStyle(.roundedBorder).font(.caption)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.08)))
    }
}

private struct DoseEditor: View {
    let itemID: String
    let planned: GroundworkDose
    let binding: (String, String) -> Binding<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Completed displayed dose. Enter only measured deviations; blank uses the displayed value.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                doseField("sets", field: "sets")
                doseField("reps", field: "reps")
                doseField("hold sec", field: "hold")
                doseField("side", field: "side", width: 90)
            }
        }
        .padding(.leading, 23)
    }

    private func doseField(_ label: String, field: String, width: CGFloat = 58) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            TextField(plannedValue(field), text: binding(itemID, field))
                .textFieldStyle(.roundedBorder).frame(width: width)
        }
    }

    private func plannedValue(_ field: String) -> String {
        switch field {
        case "sets": return planned.sets.map(String.init) ?? "—"
        case "reps": return planned.reps.map(String.init) ?? "—"
        case "hold": return planned.holdSeconds.map(String.init) ?? "—"
        case "side": return planned.side ?? "—"
        default: return "—"
        }
    }
}
