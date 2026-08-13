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

    func show(for state: SessionState) {
        dismiss(cancelTimer: true)

        let panel = FloatingPanel(size: NSSize(width: 360, height: 296), title: "MoveBreak")
        panel.setContent(
            PromptView(
                state: state,
                routines: Routines.all,
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

            VStack(spacing: 6) {
                ForEach(Array(routines.enumerated()), id: \.element.id) { index, routine in
                    ChoiceButton(
                        number: index + 1,
                        title: routine.title,
                        detail: "\(routine.subtitle) · ~\(routine.estimatedMinutes) min",
                        prominent: true
                    ) {
                        onChoose(routine)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(index + 1)")), modifiers: []
                    )
                }

                ChoiceButton(
                    number: routines.count + 1,
                    title: "Not now",
                    detail: "Skip for the rest of this session",
                    prominent: false
                ) {
                    onDecline()
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(routines.count + 1)")), modifiers: []
                )
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ChoiceButton: View {
    let number: Int
    let title: String
    let detail: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)

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
