import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let detector = SessionDetector()
    private let prompt = PromptPanelController()
    private let routineWindow = RoutineWindowController()
    private let routineBuilder = RoutineBuilderWindowController()
    private let routineStore = RoutineStore.shared

    private var statusItem: NSStatusItem?
    private var pollTimer: Timer?
    private var isPaused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        SessionLogger.shared.retryPendingSyncs()

        // The menu bar may be full, in which case the status item is never shown and this
        // is the only way to reach a running instance.
        RemoteControl.listen { [weak self] command in
            guard let self else { return }
            switch command {
            case .show:
                let state = self.detector.state == .idle ? .meeting : self.detector.state
                self.prompt.show(for: state, routines: self.routineStore.resolvedRoutines)
            case .quit:
                NSApplication.shared.terminate(nil)
            case .pause:
                self.setPaused(!self.isPaused)
            }
        }

        guard detector.isSupported else {
            reportUnsupported()
            return
        }

        // --demo / --demo-pt / --demo-builder show the panels straight away, so they can
        // be checked without waiting to be in a real meeting.
        if CommandLine.arguments.contains("--demo-pt") {
            wirePromptCallbacks()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let pt = self.routineStore.resolvedRoutines.first(where: { $0.key == "pt" })
                    ?? self.routineStore.resolvedRoutines.first
                else { return }
                self.routineWindow.show(pt.shuffledForSession())
            }
            return
        }
        if CommandLine.arguments.contains("--demo") {
            wirePromptCallbacks()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.prompt.show(for: .meeting, routines: self.routineStore.resolvedRoutines)
            }
            return
        }
        if CommandLine.arguments.contains("--demo-builder") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.routineBuilder.show(store: self.routineStore)
            }
            return
        }

        // Polling runs on a background queue, so this callback arrives off the main
        // thread. Every UI touch from here must hop back, or AppKit aborts the process.
        detector.onPromptDue = { [weak self] state in
            onMain {
                guard let self, !self.isPaused else { return }
                self.prompt.show(for: state, routines: self.routineStore.resolvedRoutines)
            }
        }
        wirePromptCallbacks()
        startPolling()
    }

    private func wirePromptCallbacks() {
        prompt.onChoose = { [weak self] routine in
            onMain {
                self?.detector.recordRoutineStarted()
                self?.routineWindow.show(routine.shuffledForSession())
            }
        }
        prompt.onDecline = { [weak self] in self?.detector.recordDecline() }
        prompt.onTimeout = { [weak self] in self?.detector.recordTimeout() }
        routineWindow.onFinish = { routine, checkedIDs in
            SessionLogger.shared.logCompletion(routine: routine, checkedIDs: checkedIDs)
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: Preferences.pollInterval, repeats: true
        ) { [weak self] _ in
            guard let self, !self.isPaused else { return }
            // The AppleScript call inside can block briefly, so keep it off the main
            // thread; the detector only calls back through onPromptDue.
            DispatchQueue.global(qos: .utility).async {
                let result = self.detector.poll()
                DispatchQueue.main.async { self.updateStatusTitle(result.state) }
            }
        }
        pollTimer?.tolerance = 0.5
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // If the SF Symbol can't be resolved the button renders with no content and
            // becomes an invisible, unclickable gap in the menu bar — so always leave a
            // visible fallback.
            if let image = NSImage(
                systemSymbolName: "figure.flexibility",
                accessibilityDescription: "MoveBreak"
            ) {
                button.image = image
            } else {
                button.title = "MB"
            }
        }
        item.menu = buildMenu()
        statusItem = item

        // The menu bar silently drops status items when it runs out of room, which looks
        // identical to the app having failed to start. Report the actual geometry so that
        // case is distinguishable.
        if CommandLine.arguments.contains("--status-check") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let frame = item.button?.window?.frame
                FileHandle.standardError.write(Data("""
                status item: visible=\(item.isVisible) \
                length=\(item.length) \
                window=\(frame.map { "\($0)" } ?? "none") \
                hasImage=\(item.button?.image != nil) \
                title=\"\(item.button?.title ?? "")\"

                """.utf8))
            }
        }
    }

    /// The routine list is now user-editable (`RoutineStore`), so the menu is built once
    /// with a placeholder gap between two separators, and `refreshRoutineItems` refills
    /// that gap on every open — see `menuNeedsUpdate`.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let status = NSMenuItem(title: "Watching for meetings…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.tag = MenuTag.status.rawValue
        menu.addItem(status)
        menu.addItem(.separator())

        let routinesEnd = NSMenuItem.separator()
        routinesEnd.tag = MenuTag.routinesEnd.rawValue
        menu.addItem(routinesEnd)

        let editRoutines = NSMenuItem(
            title: "Edit Routines…",
            action: #selector(editRoutines(_:)),
            keyEquivalent: ""
        )
        editRoutines.target = self
        menu.addItem(editRoutines)

        menu.addItem(.separator())

        let pause = NSMenuItem(
            title: "Pause Detection",
            action: #selector(togglePause(_:)),
            keyEquivalent: ""
        )
        pause.target = self
        pause.tag = MenuTag.pause.rawValue
        menu.addItem(pause)

        let quit = NSMenuItem(
            title: "Quit MoveBreak",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        refreshRoutineItems(in: menu)
        return menu
    }

    /// Removes whatever routine items are currently sitting before the `routinesEnd`
    /// separator and re-adds one per routine that has at least one exercise picked.
    private func refreshRoutineItems(in menu: NSMenu) {
        guard let endIndex = menu.items.firstIndex(where: { $0.tag == MenuTag.routinesEnd.rawValue })
        else { return }

        // Routine items sit between the first separator (index 1) and `routinesEnd`.
        for index in stride(from: endIndex - 1, through: 2, by: -1) {
            menu.removeItem(at: index)
        }

        for (offset, routine) in routineStore.resolvedRoutines.enumerated() {
            let item = NSMenuItem(
                title: routine.title,
                action: #selector(startRoutine(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = routine.key
            menu.insertItem(item, at: 2 + offset)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshRoutineItems(in: menu)
    }

    private enum MenuTag: Int {
        case status = 1
        case pause = 2
        case routinesEnd = 3
    }

    private func updateStatusTitle(_ state: SessionState) {
        guard let item = statusItem?.menu?.item(withTag: MenuTag.status.rawValue) else { return }
        if isPaused {
            item.title = "Detection paused"
            return
        }
        switch state {
        case .idle:    item.title = "Watching for meetings…"
        case .meeting: item.title = "In a meeting"
        case .video:   item.title = "Watching a video"
        }
    }

    // MARK: - Actions

    @objc private func startRoutine(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let routine = routineStore.resolvedRoutines.first(where: { $0.key == key })
        else { return }
        prompt.dismiss(cancelTimer: true)
        detector.recordRoutineStarted()
        routineWindow.show(routine.shuffledForSession())
    }

    @objc private func editRoutines(_ sender: NSMenuItem) {
        routineBuilder.show(store: routineStore)
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        setPaused(!isPaused)
    }

    private func setPaused(_ paused: Bool) {
        isPaused = paused
        statusItem?.menu?.item(withTag: MenuTag.pause.rawValue)?.title =
            paused ? "Resume Detection" : "Pause Detection"
        if paused {
            prompt.dismiss(cancelTimer: true)
        }
        updateStatusTitle(detector.state)
    }

    private func reportUnsupported() {
        guard let item = statusItem?.menu?.item(withTag: MenuTag.status.rawValue) else { return }
        item.title = "Unsupported: needs macOS 14.4+"
    }
}
