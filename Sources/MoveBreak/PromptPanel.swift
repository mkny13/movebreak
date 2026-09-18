import AppKit
import SwiftUI

enum PromptContent {
    case loading
    case offer(RoutineOfferState)
}

/// Number-key-first offer panel. A presentation ID prevents asynchronous provider results
/// from updating a prompt that was dismissed or replaced by a newer session.
final class PromptPanelController: NSObject, NSWindowDelegate {
    private var panel: FloatingPanel?
    private var timeoutTimer: Timer?
    private var presentationID: UUID?
    private var replacingPanel = false

    var onChoose: ((Routine) -> Void)?
    var onDecline: (() -> Void)?
    var onTimeout: (() -> Void)?
    var onDismiss: (() -> Void)?

    @discardableResult
    func showLoading(for state: SessionState) -> UUID {
        dismiss(cancelTimer: true)
        let id = UUID()
        presentationID = id
        render(state: state, content: .loading)
        timeoutTimer = Timer.scheduledTimer(
            withTimeInterval: Preferences.promptTimeout, repeats: false
        ) { [weak self] _ in
            guard let self, self.presentationID == id else { return }
            self.dismiss(cancelTimer: false)
            self.onTimeout?()
        }
        return id
    }

    @discardableResult
    func show(for state: SessionState, offer: RoutineOfferState) -> UUID {
        let id = showLoading(for: state)
        update(id, for: state, offer: offer)
        return id
    }

    func update(_ id: UUID, for state: SessionState, offer: RoutineOfferState) {
        guard presentationID == id else { return }
        render(state: state, content: .offer(offer))
    }

    func dismiss(cancelTimer: Bool) {
        let wasVisible = panel != nil || presentationID != nil
        presentationID = nil
        if cancelTimer {
            timeoutTimer?.invalidate()
            timeoutTimer = nil
        }
        replacingPanel = true
        panel?.delegate = nil
        panel?.close()
        replacingPanel = false
        panel = nil
        if wasVisible { onDismiss?() }
    }

    func windowWillClose(_ notification: Notification) {
        guard !replacingPanel else { return }
        presentationID = nil
        panel = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        onDismiss?()
    }

    var isVisible: Bool { panel != nil }

    private func render(state: SessionState, content: PromptContent) {
        replacingPanel = true
        panel?.delegate = nil
        panel?.close()
        replacingPanel = false

        let routineCount: Int
        switch content {
        case .loading, .offer(.empty): routineCount = 0
        case .offer(.generated): routineCount = 1
        case .offer(.local(let routines, _)): routineCount = routines.count
        case .offer(.error(_, let fallback, _)): routineCount = fallback.count
        }
        let height = min(660, 176 + CGFloat(routineCount) * 52)
        let panel = FloatingPanel(size: NSSize(width: 390, height: height), title: "MoveBreak")
        panel.delegate = self
        panel.setContent(PromptView(
            state: state,
            content: content,
            onChoose: { [weak self] routine in
                self?.dismiss(cancelTimer: true)
                self?.onChoose?(routine)
            },
            onDecline: { [weak self] in
                self?.dismiss(cancelTimer: true)
                self?.onDecline?()
            }
        ))
        panel.present()
        self.panel = panel
    }
}

private struct PromptView: View {
    let state: SessionState
    let content: PromptContent
    let onChoose: (Routine) -> Void
    let onDecline: () -> Void

    private var headline: String {
        switch state {
        case .meeting: return "You're in a meeting"
        case .video: return "You're watching something"
        case .idle: return "Time to move"
        }
    }

    private var choices: [Routine] {
        switch content {
        case .offer(.generated(let routine)): return [routine]
        case .offer(.local(let routines, _)): return routines
        case .offer(.error(_, let fallback, _)): return fallback
        default: return []
        }
    }

    private var status: (text: String, isError: Bool)? {
        switch content {
        case .loading: return ("Asking Groundwork for a \(Preferences.groundworkDurationMinutes)-minute routine…", false)
        case .offer(.generated(let routine)): return (routine.sourceLabel ?? "Groundwork routine", false)
        case .offer(.local(_, let label)): return (label, false)
        case .offer(.empty(let message)): return (message, false)
        case .offer(.error(let message, _, let fallbackLabel)):
            return ("\(message) \(fallbackLabel)", true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.headline)
                Text("Want to move a little?").font(.subheadline).foregroundStyle(.secondary)
            }

            if let status {
                HStack(alignment: .top, spacing: 7) {
                    if case .loading = content {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: status.isError ? "exclamationmark.triangle" : "info.circle")
                    }
                    Text(status.text).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(status.isError ? Color.orange : Color.secondary)
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(choices.enumerated()), id: \.element.id) { index, routine in
                        numberedChoice(
                            number: index + 1,
                            title: routine.title,
                            detail: "\(routine.subtitle) · ~\(routine.estimatedMinutes) min"
                        ) { onChoose(routine) }
                    }
                    ChoiceButton(
                        badge: "esc",
                        title: "Not now",
                        detail: "Skip for the rest of this session",
                        prominent: false,
                        action: onDecline
                    )
                    .keyboardShortcut(.cancelAction)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func numberedChoice(number: Int, title: String, detail: String, action: @escaping () -> Void) -> some View {
        let button = ChoiceButton(
            badge: "\(number)", title: title, detail: detail, prominent: true, action: action
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
                Text(badge).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: prominent ? .semibold : .regular))
                        .foregroundStyle(prominent ? .primary : .secondary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7).padding(.horizontal, 9)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(prominent ? 0.07 : 0.03)))
    }
}
