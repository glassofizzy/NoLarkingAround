import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Menu-bar agent. No dock icon (LSUIElement in Info.plist); the only UI is the
/// status item and the takeover itself.
final class AgentDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
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
        statusItem.button?.title = "◷ …"

        scheduler.onStateChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshMenu() }
        }
        scheduler.start()

        // Countdown in the status title needs its own tick; polling is only every 60s.
        menuTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.refreshMenu()
        }
        registerPauseHotKey()
        refreshMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        scheduler?.stop()
        takeover.teardown()
    }

    // MARK: - Menu

    private func refreshMenu() {
        let upcoming = scheduler.upcoming(limit: 3)
        statusItem.button?.title = statusTitle(next: upcoming.first)

        let menu = NSMenu()

        if scheduler.authExpired {
            let item = NSMenuItem(title: "⚠️  Lark sign-in expired", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(NSMenuItem(title: "Re-authenticate Lark…",
                                    action: #selector(reauth), keyEquivalent: ""))
            menu.addItem(.separator())
        } else if let err = scheduler.lastErrorText {
            let item = NSMenuItem(title: "⚠️  \(err)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if upcoming.isEmpty {
            let item = NSMenuItem(title: "No meetings in the next 18 hours",
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for a in upcoming {
                let item = NSMenuItem(
                    title: "\(Self.shortTime(a.start))  \(a.title)",
                    action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        if scheduler.isPaused {
            menu.addItem(NSMenuItem(title: "Resume alerts",
                                    action: #selector(resume), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Pause for 1 hour  (⌥⌘P)",
                                    action: #selector(pauseHour), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Pause until tomorrow",
                                    action: #selector(pauseTomorrow), keyEquivalent: ""))
        }

        let leadMenu = NSMenu()
        for minutes in [1, 3, 5, 10] {
            let item = NSMenuItem(title: "\(minutes) min",
                                  action: #selector(setLead(_:)), keyEquivalent: "")
            item.tag = minutes
            item.state = config.leadMinutes == minutes ? .on : .off
            item.target = self
            leadMenu.addItem(item)
        }
        let leadItem = NSMenuItem(title: "Lead time", action: nil, keyEquivalent: "")
        leadItem.submenu = leadMenu
        menu.addItem(leadItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Test takeover now",
                                action: #selector(testTakeover), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh calendar",
                                action: #selector(refreshNow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open config…",
                                action: #selector(openConfig), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit No Larking Around",
                                action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
    }

    private func statusTitle(next: MeetingAlert?) -> String {
        if scheduler.authExpired { return "⚠️ Lark" }
        if scheduler.isPaused { return "◷ paused" }
        guard let next else { return "◷ clear" }
        let mins = Int(next.minutesUntilStart().rounded())
        let when = mins <= 0 ? "now" : (mins < 60 ? "\(mins)m" : "\(mins / 60)h\(mins % 60)m")
        return "◷ \(when) · \(Self.truncate(next.title, 22))"
    }

    private static func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    private static func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_GB")
        return f.string(from: date)
    }

    // MARK: - Actions

    @objc private func pauseHour() { scheduler.pause(until: Date().addingTimeInterval(3600)) }

    @objc private func pauseTomorrow() {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let morning = cal.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        scheduler.pause(until: morning)
    }

    @objc private func resume() { scheduler.resume() }

    @objc private func setLead(_ sender: NSMenuItem) {
        config.leadMinutes = sender.tag
        try? config.save()
        scheduler.update(config: config)
        refreshMenu()
    }

    @objc private func refreshNow() { scheduler.poll() }

    /// Previews the takeover against the real next meeting where possible, so Join
    /// goes somewhere real instead of a placeholder URL.
    @objc private func testTakeover() {
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

    @objc private func openConfig() {
        if !FileManager.default.fileExists(atPath: Config.fileURL.path) {
            try? config.save()
        }
        NSWorkspace.shared.open(Config.fileURL)
    }

    /// `lark-cli auth login` is interactive, so it needs a real terminal.
    @objc private func reauth() {
        let script = """
        tell application "Terminal"
            activate
            do script "\(config.larkCLIPath) auth login"
        end tell
        """
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - ⌥⌘P global hot key
    //
    // Carbon's RegisterEventHotKey works without Accessibility permission, unlike
    // NSEvent.addGlobalMonitorForEvents.

    private var hotKeyRef: EventHotKeyRef?

    private func registerPauseHotKey() {
        AgentDelegate.hotKeyHandler = { [weak self] in
            guard let self else { return }
            self.scheduler.togglePause()
            // Feedback is the status title flipping to "◷ paused"; a real
            // notification would need a notarised bundle and a permission prompt.
            self.refreshMenu()
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
