import AppKit

/// Runs slow polling work one at a time and drops ticks while a poll is in flight.
/// Pause/resume generations ensure a result begun before a lifecycle change is ignored.
final class SerialPollScheduler {
    private let queue: DispatchQueue
    private let completionQueue: DispatchQueue
    private let lock = NSLock()
    private var isActive = false
    private var isStopped = false
    private var isInFlight = false
    private var generation: UInt = 0

    init(
        queue: DispatchQueue = DispatchQueue(label: "com.mike.movebreak.detection", qos: .utility),
        completionQueue: DispatchQueue = .main
    ) {
        self.queue = queue
        self.completionQueue = completionQueue
    }

    func resume() {
        lock.withLock {
            guard !isStopped else { return }
            generation &+= 1
            isActive = true
        }
    }

    func pause() {
        lock.withLock {
            generation &+= 1
            isActive = false
        }
    }

    func shutdown() {
        lock.withLock {
            generation &+= 1
            isActive = false
            isStopped = true
        }
    }

    /// Returns false when the tick was skipped because polling is paused, stopped, or busy.
    @discardableResult
    func request<Input, Output>(
        inspect: @escaping () -> Input,
        accept: @escaping (Input) -> Output,
        completion: @escaping (Output) -> Void
    ) -> Bool {
        let token: UInt? = lock.withLock {
            guard isActive, !isStopped, !isInFlight else { return nil }
            isInFlight = true
            return generation
        }
        guard let token else { return false }

        queue.async { [weak self] in
            guard let self else { return }
            let input = inspect()

            let output: Output? = self.lock.withLock {
                defer { self.isInFlight = false }
                guard self.isActive, !self.isStopped, self.generation == token else {
                    return nil
                }
                return accept(input)
            }

            guard let output else { return }
            self.completionQueue.async { [weak self] in
                guard let self else { return }
                let shouldDeliver = self.lock.withLock {
                    self.isActive && !self.isStopped && self.generation == token
                }
                if shouldDeliver { completion(output) }
            }
        }
        return true
    }

    /// Serializes non-poll detector mutations with classification acceptance.
    func perform(_ work: @escaping () -> Void) {
        let shouldSchedule = lock.withLock { !isStopped }
        if shouldSchedule { queue.async(execute: work) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let detector = SessionDetector()
    private let prompt = PromptPanelController()
    private let routineWindow = RoutineWindowController()
    private let routineBuilder = RoutineBuilderWindowController()
    private let routineStore = RoutineStore.shared
    private let routineProvider = GroundworkRoutineProvider()
    private lazy var pollScheduler = SerialPollScheduler()

    private var statusItem: NSStatusItem?
    private var pollTimer: Timer?
    private var isPaused = false
    private var detectedState: SessionState = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        SessionLogger.shared.retryPendingSyncs()

        // The menu bar may be full, in which case the status item is never shown and this
        // is the only way to reach a running instance.
        RemoteControl.listen { [weak self] command in
            guard let self else { return }
            switch command {
            case .show:
                let state = self.detectedState == .idle ? .meeting : self.detectedState
                self.showRoutineOffer(for: state)
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
                self?.routineWindow.show(Routines.demoGenerated)
            }
            return
        }
        if CommandLine.arguments.contains("--demo") {
            wirePromptCallbacks()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.prompt.show(for: .meeting, offer: .generated(Routines.demoGenerated))
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
                self.showRoutineOffer(for: state)
            }
        }
        wirePromptCallbacks()
        startPolling()

        Updater.shared.isSafeToInstall = { [weak self] in
            guard let self else { return false }
            return !self.isPaused
                && self.detectedState == .idle
                && !self.prompt.isVisible
                && !self.routineWindow.isVisible
                && !self.routineBuilder.isVisible
        }
        Updater.shared.start()
    }

    private func wirePromptCallbacks() {
        prompt.onChoose = { [weak self] routine in
            onMain {
                guard let self else { return }
                self.pollScheduler.perform { [detector = self.detector] in
                    detector.recordRoutineStarted()
                }
                self.routineWindow.show(routine.shuffledForSession())
            }
        }
        prompt.onDecline = { [weak self] in
            guard let self else { return }
            self.pollScheduler.perform { [detector = self.detector] in detector.recordDecline() }
        }
        prompt.onTimeout = { [weak self] in
            guard let self else { return }
            self.pollScheduler.perform { [detector = self.detector] in detector.recordTimeout() }
        }
        prompt.onDismiss = { [weak self] in
            self?.routineProvider.cancel()
        }
        routineWindow.onFinish = { completion in
            // Issue #7 switches delivery to the Groundwork outbox. Until then, preserve
            // local JSONL + optional Notion behavior while exposing the full typed payload.
            SessionLogger.shared.logCompletion(
                routine: completion.routine,
                checkedIDs: Set(completion.checkedItemIDs)
            )
        }
    }

    private func showRoutineOffer(for state: SessionState) {
        let presentation = prompt.showLoading(for: state)
        let localRoutines = routineStore.resolvedRoutines
        routineProvider.requestOffer(localRoutines: localRoutines) { [weak self] _, offer in
            guard let self else { return }
            self.prompt.update(presentation, for: state, offer: offer)
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollScheduler.resume()
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: Preferences.pollInterval, repeats: true
        ) { [weak self] _ in
            guard let self, !self.isPaused else { return }
            self.requestPoll()
        }
        pollTimer?.tolerance = 0.5
    }

    private func requestPoll() {
        pollScheduler.request(
            inspect: { [detector] in detector.inspect() },
            accept: { [detector] classification in
                detector.accept(classification)
                return classification
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.detectedState = result.state
                self.updateStatusTitle(result.state)
                Updater.shared.installStagedUpdateIfPossible()
            }
        )
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

        let generated = NSMenuItem(
            title: "Start Groundwork Break…",
            action: #selector(startRoutine(_:)),
            keyEquivalent: ""
        )
        generated.target = self
        generated.representedObject = MenuTag.generatedRoutineKey
        menu.insertItem(generated, at: 2)

        for (offset, routine) in routineStore.resolvedRoutines.enumerated() {
            let item = NSMenuItem(
                title: "Local: \(routine.title)",
                action: #selector(startRoutine(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = routine.key
            menu.insertItem(item, at: 3 + offset)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshRoutineItems(in: menu)
    }

    private enum MenuTag: Int {
        static let generatedRoutineKey = "__groundwork__"
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
        guard let key = sender.representedObject as? String else { return }
        if key == MenuTag.generatedRoutineKey {
            showRoutineOffer(for: detectedState)
            return
        }
        guard
              let routine = routineStore.resolvedRoutines.first(where: { $0.key == key })
        else { return }
        prompt.dismiss(cancelTimer: true)
        pollScheduler.perform { [detector] in detector.recordRoutineStarted() }
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
        if paused {
            pollScheduler.pause()
        } else {
            pollScheduler.resume()
        }
        statusItem?.menu?.item(withTag: MenuTag.pause.rawValue)?.title =
            paused ? "Resume Detection" : "Pause Detection"
        if paused {
            prompt.dismiss(cancelTimer: true)
        }
        updateStatusTitle(detectedState)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        pollScheduler.shutdown()
        routineProvider.cancel()
    }

    private func reportUnsupported() {
        guard let item = statusItem?.menu?.item(withTag: MenuTag.status.rawValue) else { return }
        item.title = "Unsupported: needs macOS 14.4+"
    }
}
