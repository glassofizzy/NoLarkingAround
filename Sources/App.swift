import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Menu-bar agent. No dock icon (LSUIElement in Info.plist); the only UI is the
/// status pill, its dropdown panel, and the takeover itself.
final class AgentDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menuModel = MenuViewModel()
    private lazy var menuPanel = MenuPanelController(model: menuModel)
    private let takeover = TakeoverController()
    private var store: EventStore!
    private var scheduler: AlertScheduler!
    private var config: Config
    private var menuTimer: Timer?

    init(config: Config) {
        self.config = config
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontLoader.shared.register()

        let client = LarkClient(cliPath: config.larkCLIPath)
        store = EventStore(client: client, config: config)
        scheduler = AlertScheduler(store: store, takeover: takeover, config: config)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "◷ …"
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePanel(_:))
            // Fire on mouse-down, like a native menu, not on release.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        menuPanel.onAction = { [weak self] action in self?.handle(action) }

        scheduler.onStateChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshUI() }
        }
        scheduler.start()

        // Countdown in the status pill needs its own tick; polling is only every 60s.
        menuTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refreshUI()
        }
        registerPauseHotKey()
        refreshUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        scheduler?.stop()
        takeover.teardown()
    }

    // MARK: - Menu

    /// Repaints the status pill and feeds the panel a fresh snapshot. An open
    /// panel observes the model, so it updates live on the 20s tick.
    private func refreshUI() {
        let upcoming = scheduler.upcoming(limit: 3)

        let pill = PillState.make(next: upcoming.first, authExpired: scheduler.authExpired,
                                  isPaused: scheduler.isPaused)
        if let button = statusItem.button {
            let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            if let image = StatusPillRenderer.image(for: pill, scale: scale) {
                button.image = image
                button.title = ""
            } else {
                button.image = nil
                button.title = pill.plainTitle
            }
            button.setAccessibilityLabel(pill.plainTitle)
        }

        let snapshot = MenuSnapshot.make(
            upcoming: upcoming, authExpired: scheduler.authExpired,
            errorText: scheduler.lastErrorText, isPaused: scheduler.isPaused,
            leadMinutes: config.leadMinutes)
        if snapshot != menuModel.snapshot { menuModel.snapshot = snapshot }
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        menuPanel.toggle(relativeTo: sender)
    }

    private func handle(_ action: MenuAction) {
        switch action {
        case .reauth:        reauth()
        case .pauseHour:     pauseHour()
        case .pauseTomorrow: pauseTomorrow()
        case .resume:        resume()
        case .setLead(let m): setLead(m)
        case .testTakeover:  testTakeover()
        case .refresh:       refreshNow()
        case .openConfig:    openConfig()
        case .quit:          quit()
        }
    }

    // MARK: - Actions

    private func pauseHour() { scheduler.pause(until: Date().addingTimeInterval(3600)) }

    private func pauseTomorrow() {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let morning = cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        scheduler.pause(until: morning)
    }

    private func resume() { scheduler.resume() }

    private func setLead(_ minutes: Int) {
        config.leadMinutes = minutes
        try? config.save()
        scheduler.update(config: config)
        refreshUI()
    }

    private func refreshNow() { scheduler.poll() }

    /// Previews the takeover against the real next meeting where possible, so Join
    /// goes somewhere real instead of a placeholder URL.
    private func testTakeover() {
        if let real = scheduler.upcoming(limit: 1).first {
            takeover.show(alert: real, leadMinutes: config.leadMinutes,
                          soundName: config.soundName) { [weak self] action in
                if case .join(let url) = action { self?.openJoin(url) }
            }
            return
        }

        let start = Date().addingTimeInterval(Double(config.leadMinutes) * 60)
        let sample = MeetingAlert(
            eventID: "__test__", title: "Test takeover",
            start: start, end: start.addingTimeInterval(1800),
            timeRange: MeetingAlert.formatRange(start: start,
                                                end: start.addingTimeInterval(1800)),
            durationLabel: "30 min", attendanceLabel: "2 invited",
            roomSlab: "CPT-L10-A13(2)", floorLabel: "SG · Capital Tower",
            hostName: "You", hostTag: "YOU HOST", hostIsMe: true,
            participantNames: ["Dan Whitfield"], moreLabel: nil,
            // No placeholder link: a dead meeting URL is worse than no button.
            joinURL: nil,
            clashLabel: nil
        )
        takeover.show(alert: sample, leadMinutes: config.leadMinutes,
                      soundName: config.soundName) { _ in }
    }

    private func openJoin(_ url: URL) { NSWorkspace.shared.open(url) }

    private func openConfig() {
        if !FileManager.default.fileExists(atPath: Config.fileURL.path) {
            try? config.save()
        }
        NSWorkspace.shared.open(Config.fileURL)
    }

    /// `lark-cli auth login` is interactive, so it needs a real terminal. We open a
    /// `.command` file via LaunchServices rather than AppleScript-driving Terminal —
    /// the AppleScript route needs Automation (Apple Events) permission that this
    /// LaunchAgent-run app has no reliable way to prompt for, and failed silently.
    private func reauth() {
        let script = "#!/bin/bash\nexec \"\(config.larkCLIPath)\" auth login\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nolarkingaround-reauth-\(UUID().uuidString).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't open a terminal to re-authenticate"
            alert.informativeText = "Run this manually in Terminal:\n\(config.larkCLIPath) auth login\n\n(\(error.localizedDescription))"
            alert.runModal()
        }
    }

    private func quit() { NSApp.terminate(nil) }

    // MARK: - ⌥⌘P global hot key
    //
    // Carbon's RegisterEventHotKey works without Accessibility permission, unlike
    // NSEvent.addGlobalMonitorForEvents.

    private var hotKeyRef: EventHotKeyRef?

    private func registerPauseHotKey() {
        AgentDelegate.hotKeyHandler = { [weak self] in
            guard let self else { return }
            self.scheduler.togglePause()
            // Feedback is the status pill flipping to "Paused"; a real
            // notification would need a notarised bundle and a permission prompt.
            self.refreshUI()
            NSSound(named: self.scheduler.isPaused ? "Bottle" : "Pop")?.play()
        }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            AgentDelegate.hotKeyHandler?()
            return noErr
        }, 1, &spec, nil, nil)

        let id = EventHotKeyID(signature: OSType(0x494B4C50), id: 1)  // 'IKLP'
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_P),
            UInt32(optionKey | cmdKey),
            id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            FileHandle.standardError.write(
                "warning: could not register ⌥⌘P (status \(status)); use the menu to pause\n"
                    .data(using: .utf8)!)
        }
    }

    private static var hotKeyHandler: (() -> Void)?

}
