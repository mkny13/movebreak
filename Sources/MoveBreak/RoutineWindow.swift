import AppKit
import SwiftUI

/// The checklist that appears once a routine is picked. Self-paced: check things off as
/// you go, no timer running against you.
final class RoutineWindowController {

    private var panel: FloatingPanel?
    var onFinish: (() -> Void)?

    func show(_ routine: Routine) {
        close()

        let panel = FloatingPanel(size: NSSize(width: 380, height: 520), title: routine.title)
        panel.setContent(
            RoutineView(routine: routine) { [weak self] in
                self?.close()
                self?.onFinish?()
            }
        )
        panel.present()
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

private struct RoutineView: View {
    let routine: Routine
    let onDone: () -> Void

    @State private var checked: Set<UUID> = []

    private var grouped: [(area: String, exercises: [Exercise])] {
        // Preserve authored order rather than sorting — routines are deliberately
        // sequenced (walk-safe work first in PT).
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(grouped, id: \.area) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.area.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)

                            ForEach(group.exercises) { exercise in
                                ExerciseRow(
                                    exercise: exercise,
                                    isChecked: checked.contains(exercise.id)
                                ) {
                                    toggle(exercise)
                                }
                            }
                        }
                    }

                    Text(Routines.disclaimer)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.top, 4)
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
                Text(routine.title)
                    .font(.headline)
                Spacer()
                Text("\(checked.count)/\(routine.exercises.count)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text("\(routine.subtitle) · ~\(routine.estimatedMinutes) min")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    /// Legend for the per-exercise badges. Both symbols need explaining, not just one —
    /// the badge is the whole point of the treadmill tagging.
    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(TreadmillTag.walkSafe.badge) keep walking")
            Text("\(TreadmillTag.pauseTreadmill.badge) pause belt")
            Spacer(minLength: 0)
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func toggle(_ exercise: Exercise) {
        if checked.contains(exercise.id) {
            checked.remove(exercise.id)
        } else {
            checked.insert(exercise.id)
        }
    }
}

private struct ExerciseRow: View {
    let exercise: Exercise
    let isChecked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                    .font(.system(size: 14))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(exercise.name)
                            .font(.system(size: 12, weight: .medium))
                            .strikethrough(isChecked, color: .secondary)
                        Text(exercise.treadmill.badge)
                            .font(.system(size: 10))
                            .help(exercise.treadmill.help)
                    }
                    Text(exercise.dose)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(exercise.cue)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .opacity(isChecked ? 0.5 : 1)
            .padding(.vertical, 5)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
