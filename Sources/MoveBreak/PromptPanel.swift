import AppKit
import SwiftUI

/// The four-choice popup that appears when a session is detected.
///
/// Choices are numbered and bound to keys 1–4 so it can be dismissed or acted on without
/// reaching for the mouse — useful when you're mid-meeting.
final class PromptPanelController {

    private var panel: FloatingPanel?
    private var timeoutTimer: Timer?

    var onChoose: ((Routine) -> Void)?
    var onDecline: (() -> Void)?
    var onTimeout: (() -> Void)?

    /// Routines vary in count now that they come from `RoutineStore`, so the panel's
    /// height grows with them rather than being fixed.
    func show(for state: SessionState, routines: [Routine]) {
        dismiss(cancelTimer: true)

        let rowCount = routines.count + 1  // + "Not now"
        let height = min(620, 112 + CGFloat(rowCount) * 46)
        let panel = FloatingPanel(size: NSSize(width: 360, height: height), title: "MoveBreak")
        panel.setContent(
            PromptView(
                state: state,
                routines: routines,
                onChoose: { [weak self] routine in
                    self?.dismiss(cancelTimer: true)
                    self?.onChoose?(routine)
                },
                onDecline: { [weak self] in
                    self?.dismiss(cancelTimer: true)
                    self?.onDecline?()
                }
            )
        )
        panel.present()
        self.panel = panel

        // Unanswered prompts get a softer cooldown than an explicit "Not now" — you were
        // probably just busy, not saying no.
        timeoutTimer = Timer.scheduledTimer(
            withTimeInterval: Preferences.promptTimeout, repeats: false
        ) { [weak self] _ in
            self?.dismiss(cancelTimer: false)
            self?.onTimeout?()
        }
    }

    func dismiss(cancelTimer: Bool) {
        if cancelTimer {
            timeoutTimer?.invalidate()
            timeoutTimer = nil
        }
        panel?.close()
        panel = nil
    }

    var isVisible: Bool { panel != nil }
}

private struct PromptView: View {
    let state: SessionState
    let routines: [Routine]
    let onChoose: (Routine) -> Void
    let onDecline: () -> Void

    private var headline: String {
        switch state {
        case .meeting: return "You're in a meeting"
        case .video:   return "You're watching something"
        case .idle:    return "Time to move"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.headline)
                Text("Want to move a little?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(routines.enumerated()), id: \.element.id) { index, routine in
                        numberedChoice(
                            number: index + 1,
                            title: routine.title,
                            detail: "\(routine.subtitle) · ~\(routine.estimatedMinutes) min",
                            prominent: true
                        ) {
                            onChoose(routine)
                        }
                    }

                    ChoiceButton(
                        badge: "esc",
                        title: "Not now",
                        detail: "Skip for the rest of this session",
                        prominent: false
                    ) {
                        onDecline()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// `Character("10")` traps — routine counts are user-defined now, so past 9 a choice
    /// still shows its number but drops the keyboard shortcut rather than crashing.
    @ViewBuilder
    private func numberedChoice(
        number: Int, title: String, detail: String, prominent: Bool, action: @escaping () -> Void
    ) -> some View {
        let button = ChoiceButton(
            badge: "\(number)", title: title, detail: detail, prominent: prominent, action: action
        )
        if number <= 9 {
            button.keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [])
        } else {
            button
        }
    }
}

private struct ChoiceButton: View {
    let badge: String
    let title: String
    let detail: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(badge)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: prominent ? .semibold : .regular))
                        .foregroundStyle(prominent ? .primary : .secondary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(prominent ? 0.07 : 0.03))
        )
    }
}
