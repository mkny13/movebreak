import AppKit
import SwiftUI

/// A panel that floats above a full-screen meeting without stealing focus.
///
/// Three settings do the real work here, and all three matter:
///   • `.nonactivatingPanel` — clicking it doesn't pull you out of Zoom
///   • `.floating` level      — stays above ordinary windows
///   • `.fullScreenAuxiliary` — without this the panel simply will not appear over a
///     full-screen Zoom window, which is the main way this app gets used
final class FloatingPanel: NSPanel {

    init(size: NSSize, title: String) {
        // AppKit windows must be constructed on the main thread; doing it from a
        // background queue raises and aborts the process. Fail loudly here rather than
        // deep inside NSWindow, where the backtrace hides the actual caller.
        dispatchPrecondition(condition: .onQueue(.main))
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.title = title
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        // Take key status only when the user actually interacts, so keyboard shortcuts
        // work without the panel grabbing focus the moment it appears.
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    /// Needed for keyboard handling — an NSPanel refuses key status by default.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func setContent<Content: View>(_ view: Content) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        contentView = hosting
    }

    /// Park it in the top-right of whichever screen the cursor is on, so on a multi-monitor
    /// setup it lands where you're actually looking.
    func positionTopRight(margin: CGFloat = 20) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        setFrameOrigin(NSPoint(
            x: visible.maxX - frame.width - margin,
            y: visible.maxY - frame.height - margin
        ))
    }

    /// Show without activating the app — the meeting keeps focus.
    func present() {
        positionTopRight()
        orderFrontRegardless()
    }
}
