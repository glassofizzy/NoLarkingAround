import AppKit
import Combine
import SwiftUI

/// Borderless, transparent panel that can take keys without activating the app,
/// so opening it doesn't pull focus from whatever the user is working in.
final class MenuPanelWindow: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Keys are intercepted here rather than in keyDown: NSHostingView is first
    /// responder and may consume arrows before they reach the window.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Replaces NSMenu for the status item, and so re-implements what NSMenu gave for
/// free: toggle on click, dismiss on outside click / Esc / focus loss, arrow-key
/// navigation, and the status button's pressed state.
final class MenuPanelController {
    let model: MenuViewModel
    /// Receives every action; the controller closes the panel first where needed.
    var onAction: (MenuAction) -> Void = { _ in }

    private var panel: MenuPanelWindow?
    private var hosting: NSHostingView<MenuPanelView>?
    private weak var button: NSStatusBarButton?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var modelSink: AnyCancellable?
    /// Guards against close-then-reopen when one click both resigns key and hits
    /// the status button.
    private var lastClosed = Date.distantPast

    var isOpen: Bool { panel?.isVisible ?? false }

    init(model: MenuViewModel) {
        self.model = model
        model.onAction = { [weak self] action in
            guard let self else { return }
            if case .setLead = action {} else { self.close() }
            self.onAction(action)
        }
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if isOpen {
            close()
        } else if Date().timeIntervalSince(lastClosed) > 0.25 {
            open(relativeTo: button)
        }
    }

    func open(relativeTo button: NSStatusBarButton) {
        self.button = button
        let panel = self.panel ?? makePanel()
        self.panel = panel
        layout()
        panel.orderFrontRegardless()
        panel.makeKey()
        button.highlight(true)
        installDismissal()

        // Expanding lead time or a live snapshot tick changes the card's height.
        modelSink = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
        }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        button?.highlight(false)
        removeDismissal()
        modelSink = nil
        model.reset()
        lastClosed = Date()
    }

    // MARK: Window

    private func makePanel() -> MenuPanelWindow {
        let p = MenuPanelWindow(contentRect: .zero,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.acceptsMouseMovedEvents = true
        p.appearance = NSAppearance(named: .aqua)   // the card is always light

        let host = NSHostingView(rootView: MenuPanelView(model: model))
        p.contentView = host
        hosting = host

        p.onCancel = { [weak self] in self?.close() }
        p.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        return p
    }

    private func layout() {
        guard let panel, let hosting, let button, let bwin = button.window else { return }
        let size = hosting.fittingSize
        let buttonRect = bwin.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = (bwin.screen ?? NSScreen.main)?.visibleFrame ?? buttonRect
        let frame = Self.frame(button: buttonRect, size: size, visible: screen)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    /// Top-left under the button's left edge, clamped inside the visible frame.
    static func frame(button: NSRect, size: NSSize, visible: NSRect) -> NSRect {
        let gap: CGFloat = 4, margin: CGFloat = 4
        var x = button.minX
        x = min(x, visible.maxX - size.width - margin)
        x = max(x, visible.minX + margin)
        let top = min(button.minY - gap, visible.maxY)
        let y = max(top - size.height, visible.minY)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: Keyboard

    private func handleKey(_ e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command) {
            if e.charactersIgnoringModifiers?.lowercased() == "q" {
                model.activate(.quit)
                return true
            }
            return false
        }
        switch Int(e.keyCode) {
        case 126: model.move(-1); return true                  // ↑
        case 125: model.move(1); return true                   // ↓
        case 36, 76, 49: model.activateHighlighted(); return true   // Return, Enter, Space
        case 124:                                              // →
            if model.highlighted == .leadTime { model.setLeadExpanded(true); model.move(1) }
            return true
        case 123:                                              // ←
            if model.leadExpanded { model.setLeadExpanded(false) }
            return true
        case 53: close(); return true                          // Esc
        default: return false
        }
    }

    // MARK: Dismissal

    private func installDismissal() {
        removeDismissal()
        // Clicks in other apps. Mouse (unlike key) global monitors need no
        // Accessibility permission.
        if let m = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] _ in self?.close() }) {
            monitors.append(m)
        }
        // Clicks in our own windows other than the panel. The status button is
        // left alone so its action can toggle.
        if let m = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] event in
                guard let self else { return event }
                if event.window !== self.panel && event.window !== self.button?.window {
                    self.close()
                }
                return event
            }) {
            monitors.append(m)
        }

        let nc = NotificationCenter.default
        if let panel {
            observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification,
                                            object: panel, queue: .main) { [weak self] _ in
                self?.close()
            })
        }
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            self?.close()
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.close()
        })
    }

    private func removeDismissal() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
    }
}
