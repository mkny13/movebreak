import AppKit
import SwiftUI

/// "Edit Routines…" — pick exercises from the full catalog into one or more named
/// routines. Opened deliberately from the menu bar, not tied to a meeting, so unlike the
/// other panels it's centered rather than parked in the corner.
final class RoutineBuilderWindowController {

    private var panel: FloatingPanel?

    func show(store: RoutineStore) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let panel = FloatingPanel(size: NSSize(width: 640, height: 560), title: "Edit Routines")
        panel.setContent(RoutineBuilderView(store: store) { [weak self] in
            self?.close()
        })
        panel.presentCentered()
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

private struct RoutineBuilderView: View {
    @ObservedObject var store: RoutineStore
    let onDone: () -> Void

    @State private var selectedRoutineID: String?

    private var selected: SavedRoutine? {
        store.routines.first { $0.id == selectedRoutineID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                if let selected {
                    editor(for: selected)
                } else {
                    emptyState
                }
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if selectedRoutineID == nil {
                selectedRoutineID = store.routines.first?.id
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(store.routines, selection: $selectedRoutineID) { routine in
                HStack {
                    Text(routine.name.isEmpty ? "Untitled" : routine.name)
                    Spacer()
                    Text("\(routine.exerciseIDs.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .tag(routine.id)
                .contextMenu {
                    Button("Delete", role: .destructive) { delete(routine.id) }
                }
            }
            .listStyle(.sidebar)

            Divider()

            Button {
                let routine = store.addRoutine(named: "New Routine")
                selectedRoutineID = routine.id
            } label: {
                Label("New Routine", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .frame(width: 200)
    }

    private func delete(_ id: String) {
        let wasSelected = selectedRoutineID == id
        store.delete(id)
        if wasSelected {
            selectedRoutineID = store.routines.first?.id
        }
    }

    // MARK: - Editor

    private func editor(for routine: SavedRoutine) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Routine name", text: nameBinding(for: routine.id))
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))

                let minutes = RoutineStore.estimatedMinutes(forExerciseCount: routine.exerciseIDs.count)
                Text(routine.exerciseIDs.isEmpty
                     ? "Pick exercises below"
                     : "\(routine.exerciseIDs.count) exercises · ~\(minutes) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ExerciseCatalog.groupedByArea, id: \.area) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.area.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)

                            ForEach(group.exercises) { exercise in
                                CatalogRow(
                                    exercise: exercise,
                                    isIncluded: routine.exerciseIDs.contains(exercise.id)
                                ) { included in
                                    store.setExercise(exercise.id, included: included, in: routine.id)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }

    private func nameBinding(for id: String) -> Binding<String> {
        Binding(
            get: { store.routines.first { $0.id == id }?.name ?? "" },
            set: { store.rename(id, to: $0) }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No routines yet")
                .font(.headline)
            Button("New Routine") {
                let routine = store.addRoutine(named: "New Routine")
                selectedRoutineID = routine.id
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("Routines need at least one exercise to appear in the prompt or menu.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct CatalogRow: View {
    let exercise: Exercise
    let isIncluded: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        Button {
            onToggle(!isIncluded)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isIncluded ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isIncluded ? Color.accentColor : Color.secondary)
                    .font(.system(size: 13))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(exercise.name)
                            .font(.system(size: 12, weight: .medium))
                        Text(exercise.treadmill.badge)
                            .font(.system(size: 10))
                            .help(exercise.treadmill.help)
                    }
                    Text(exercise.dose)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
