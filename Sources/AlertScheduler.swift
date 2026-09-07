import AppKit
import Foundation

/// Lets the scheduler be driven in tests without creating real windows.
protocol TakeoverPresenting: AnyObject {
    var isShowing: Bool { get }
    func show(alert: MeetingAlert, leadMinutes: Int, soundName: String?,
              onAction: @escaping (TakeoverAction) -> Void)
    func teardown()
}

extension TakeoverController: TakeoverPresenting {}

/// Per-occurrence user decisions. Keyed by event_id, which for recurring events
/// already includes the instance timestamp.
private struct AlertState {
    var joined = false
    var dismissed = false
    var snoozedUntilStart = false
    var firedLead = false
    var firedStart = false
}

/// Decides when a takeover appears and remembers what the user did about it.
///
/// Evaluated on a 1s tick rather than by arming a timer per fire time: it is
/// negligible in cost and inherently correct across sleep/wake, where a precisely
/// armed timer would either fire late in a burst or not at all.
final class AlertScheduler {
    private let store: EventStore
    private let takeover: TakeoverPresenting
    private var config: Config

    /// Overridable so tests can drive a virtual clock.
    var clock: () -> Date = { Date() }
    /// When set, evaluation uses these instead of polling Lark.
    var alertsOverride: [MeetingAlert]?
    /// Overridable so the self-test never opens a real browser window.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private var states: [String: AlertState] = [:]
    /// Fully-resolved alerts, main-thread only. Built on `larkQueue`.
    private var alerts: [MeetingAlert] = []
    private var lastPoll: Date?
    private var lastError: LarkError?
    private var polling = false

    /// All EventStore access is serialised here. Each lark-cli call spawns node and
    /// costs a few hundred ms, so doing this on main would stall the menu bar.
    private let larkQueue = DispatchQueue(label: "com.traveloka.inyourlark.lark")

    private var tick: Timer?
    private var showingEventID: String?
    private var autoClearAt: Date?

    /// Global pause; nil means running.
    private(set) var pausedUntil: Date?

    var onStateChange: (() -> Void)?

    init(store: EventStore, takeover: TakeoverPresenting, config: Config) {
        self.store = store
        self.takeover = takeover
        self.config = config
    }

    // MARK: - Lifecycle

    func start() {
        poll()
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        tick?.tolerance = 0.25
    }

    func stop() {
        tick?.invalidate()
        tick = nil
    }

    func update(config: Config) {
        self.config = config
        larkQueue.async { [weak self] in self?.store.update(config: config) }
        poll()
        onStateChange?()
    }

    // MARK: - State for the menu bar

    var isPaused: Bool {
        guard let until = pausedUntil else { return false }
        return until > clock()
    }

    var authExpired: Bool { lastError?.isAuthExpired ?? false }
    var lastErrorText: String? { lastError.map(\.description) }

    /// Alertable meetings still ahead of us, soonest first.
    func upcoming(limit: Int = 3) -> [MeetingAlert] {
        let now = clock()
        return currentAlerts()
            .filter { $0.end > now && !(states[$0.eventID]?.dismissed ?? false) }
            .sorted { $0.start < $1.start }
            .prefix(limit)
            .map { $0 }
    }

    /// Alerts under consideration: the override when testing, else the live poll.
    private func currentAlerts() -> [MeetingAlert] {
        alertsOverride ?? alerts
    }

    func pause(until date: Date) {
        pausedUntil = date
        takeover.teardown()
        showingEventID = nil
        onStateChange?()
    }

    func resume() {
        pausedUntil = nil
        onStateChange?()
    }

    func togglePause() {
        if isPaused { resume() } else { pause(until: Date().addingTimeInterval(3600)) }
    }

    // MARK: - Polling

    func poll() {
        if alertsOverride != nil { return }
        guard !polling else { return }
        polling = true

        larkQueue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            var built: [MeetingAlert] = []
            var failure: LarkError?
            do {
                if self.store.myOpenID == nil { try self.store.resolveIdentity() }
                let events = try self.store.fetchAgenda(
                    from: now, to: now.addingTimeInterval(18 * 3600))
                // No attendee window: resolve every event now. Lookups are cached
                // per event, so this costs a burst on the first poll and almost
                // nothing after. A window meant distant events were shown with an
                // empty attendee list — no participant pills, wrong invite count.
                let classified = self.store.classify(
                    events: events, now: now, attendeeWindow: nil)
                built = classified
                    .filter { $0.verdict.isAlert }
                    .compactMap { self.store.buildAlert(for: $0) }
            } catch let e as LarkError {
                failure = e
            } catch {
                failure = .badOutput(String(describing: error))
            }

            DispatchQueue.main.async {
                self.alerts = built
                self.lastError = failure
                self.lastPoll = Date()
                self.polling = false
                let live = Set(built.map(\.eventID))
                self.states = self.states.filter { live.contains($0.key) }
                self.onStateChange?()
            }
        }
    }

    // MARK: - Evaluation

    func evaluate() {
        let now = clock()

        if let due = lastPoll?.addingTimeInterval(TimeInterval(config.pollSeconds)),
           now >= due {
            poll()
        }

        // Auto-clear the at-start takeover so a meeting you skip does not leave the
        // screen blocked indefinitely.
        if let clearAt = autoClearAt, now >= clearAt {
            takeover.teardown()
            showingEventID = nil
            autoClearAt = nil
        }

        guard !takeover.isShowing, !isPaused, !config.isQuiet(at: now) else { return }

        for alert in currentAlerts() {
            var state = states[alert.eventID] ?? AlertState()
            if state.joined || state.dismissed { continue }

            let leadAt = alert.start.addingTimeInterval(-Double(config.leadMinutes) * 60)
            let startAt = alert.start

            // Lead alert: only inside [leadAt, start). Past that we let the
            // at-start alert handle it rather than firing a stale takeover.
            if !state.firedLead, !state.snoozedUntilStart,
               now >= leadAt, now < startAt {
                state.firedLead = true
                states[alert.eventID] = state
                // Must have an auto-clear too: an ignored lead takeover would
                // otherwise sit on screen indefinitely, since `isShowing` blocks
                // the at-start alert from ever replacing it.
                present(alert, autoClear: startAt.addingTimeInterval(
                    TimeInterval(config.autoClearSeconds)))
                return
            }

            // At-start alert, within its auto-clear window.
            if config.alsoAtStart, !state.firedStart, now >= startAt,
               now < startAt.addingTimeInterval(TimeInterval(config.autoClearSeconds)) {
                state.firedStart = true
                states[alert.eventID] = state
                present(alert, autoClear: startAt.addingTimeInterval(
                    TimeInterval(config.autoClearSeconds)))
                return
            }

            states[alert.eventID] = state
        }
    }

    private func present(_ alert: MeetingAlert, autoClear: Date?) {
        showingEventID = alert.eventID
        autoClearAt = autoClear

        takeover.show(alert: alert, leadMinutes: config.leadMinutes,
                      soundName: config.soundName) { [weak self] action in
            guard let self else { return }
            var state = self.states[alert.eventID] ?? AlertState()
            switch action {
            case .join(let url):
                state.joined = true
                self.openURL(url)
            case .dismiss:
                // Per instruction, Dismiss kills the occurrence: no at-start re-fire.
                state.dismissed = true
            case .snoozeUntilStart:
                state.snoozedUntilStart = true
            }
            self.states[alert.eventID] = state
            self.showingEventID = nil
            self.autoClearAt = nil
            self.onStateChange?()
        }
    }
}
