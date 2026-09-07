import AppKit
import SwiftUI

/// Borderless window that can still take clicks. A plain borderless NSWindow
/// reports canBecomeKey == false, which stops it receiving keyboard focus and can
/// swallow interaction with the hosted SwiftUI controls.
final class TakeoverPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Esc is deliberately inert: the only ways out are Join, Dismiss and Snooze.
    override func cancelOperation(_ sender: Any?) {}
}

/// Owns one window per screen and keeps them in step with display changes.
final class TakeoverController {
    private var windows: [TakeoverPanel] = []
    private var current: (alert: MeetingAlert, leadMinutes: Int)?
    private var handler: ((TakeoverAction) -> Void)?
    private var observer: NSObjectProtocol?

    var isShowing: Bool { !windows.isEmpty }

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Monitor plugged or unplugged mid-takeover: rebuild to cover the new layout.
            guard let self, let c = self.current, let h = self.handler else { return }
            self.teardown()
            self.show(alert: c.alert, leadMinutes: c.leadMinutes, onAction: h)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func show(alert: MeetingAlert, leadMinutes: Int, soundName: String? = nil,
              onAction: @escaping (TakeoverAction) -> Void) {
        teardown()
        current = (alert, leadMinutes)
        handler = onAction

        let wrapped: (TakeoverAction) -> Void = { [weak self] action in
            self?.teardown()
            onAction(action)
        }

        for screen in NSScreen.screens {
            let panel = TakeoverPanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            // Above other apps' fullscreen windows, and present on every Space.
            panel.level = NSWindow.Level(
                rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
            panel.collectionBehavior = [
                .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
            ]
            panel.isOpaque = true
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.backgroundColor = NSColor(srgbRed: 0xA4 / 255, green: 0xE2 / 255,
                                            blue: 0xEE / 255, alpha: 1)
            panel.contentView = NSHostingView(
                rootView: TakeoverView(
                    alert: alert, leadMinutes: leadMinutes, onAction: wrapped
                )
            )
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            windows.append(panel)
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()

        if let soundName, let sound = NSSound(named: soundName) {
            sound.play()
        }
    }

    func teardown() {
        for w in windows {
            w.orderOut(nil)
            w.contentView = nil
            w.close()
        }
        windows.removeAll()
        current = nil
        handler = nil
    }
}
