import Combine
import Foundation

/// Menu-bar state with no AppKit in it, so grouping, countdown text and keyboard
/// navigation can be self-tested without a window.

// MARK: - Snapshot

struct MenuMeetingRow: Equatable {
    let time: String
    let title: String
    let isNext: Bool
}

struct MenuDayGroup: Equatable {
    /// "TODAY · FRI 4 SEPT"
    let header: String
    let rows: [MenuMeetingRow]
}

struct MenuSnapshot: Equatable {
    var groups: [MenuDayGroup] = []
    var authExpired = false
    /// Non-auth poll error, shown verbatim above the meetings.
    var errorText: String?
    var isPaused = false
    var leadMinutes = 3

    static let leadChoices = [1, 3, 5, 10]

    /// Groups by start day. A meeting already under way counts as today, and the
    /// first row overall is the "next" one the design highlights.
    static func make(upcoming: [MeetingAlert], now: Date = Date(),
                     calendar: Calendar = .current,
                     authExpired: Bool, errorText: String?,
                     isPaused: Bool, leadMinutes: Int) -> MenuSnapshot {
        var groups: [MenuDayGroup] = []
        var currentDay: Date?
        var rows: [MenuMeetingRow] = []

        for (i, a) in upcoming.enumerated() {
            let day = calendar.startOfDay(for: max(a.start, now))
            if day != currentDay {
                if let d = currentDay {
                    groups.append(MenuDayGroup(header: header(for: d, now: now, calendar: calendar),
                                               rows: rows))
                }
                currentDay = day
                rows = []
            }
            rows.append(MenuMeetingRow(time: shortTime(a.start), title: a.title, isNext: i == 0))
        }
        if let d = currentDay {
            groups.append(MenuDayGroup(header: header(for: d, now: now, calendar: calendar),
                                       rows: rows))
        }

        return MenuSnapshot(groups: groups, authExpired: authExpired,
                            errorText: authExpired ? nil : errorText,
                            isPaused: isPaused, leadMinutes: leadMinutes)
    }

    static func header(for day: Date, now: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "EEE d MMM"
        let date = f.string(from: day).uppercased().replacingOccurrences(of: ".", with: "")
        if calendar.isDate(day, inSameDayAs: now) { return "TODAY · \(date)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           calendar.isDate(day, inSameDayAs: tomorrow) {
            return "TOMORROW · \(date)"
        }
        return date
    }

    static func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_GB")
        return f.string(from: date)
    }
}

// MARK: - Status pill

struct PillState: Equatable {
    enum Tone { case accent, paper }

    /// Dark inset badge, e.g. "1h7m". Nil draws text only.
    let badge: String?
    let text: String
    let tone: Tone

    static func make(next: MeetingAlert?, now: Date = Date(),
                     authExpired: Bool, isPaused: Bool) -> PillState {
        if authExpired { return PillState(badge: "!", text: "Lark sign-in", tone: .accent) }
        if isPaused { return PillState(badge: nil, text: "Paused", tone: .paper) }
        guard let next else { return PillState(badge: nil, text: "All clear", tone: .paper) }
        let mins = Int(next.minutesUntilStart(now: now).rounded())
        return PillState(badge: countdownText(minutes: mins),
                         text: truncate(next.title, 22), tone: .accent)
    }

    /// 0 or less → "now", under an hour → "45m", otherwise "1h7m".
    static func countdownText(minutes: Int) -> String {
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h\(minutes % 60)m"
    }

    /// Plain-text title for when the pill can't be rendered as an image.
    var plainTitle: String {
        badge.map { "◷ \($0) · \(text)" } ?? "◷ \(text)"
    }

    static func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }
}

// MARK: - Actions and navigation

enum MenuAction: Equatable {
    case reauth, pauseHour, pauseTomorrow, resume, setLead(Int)
    case testTakeover, refresh, openConfig, quit
}

/// Every selectable row, in on-screen order. Arrow keys and hover share this list.
enum MenuRowID: Hashable {
    case reauth, pauseHour, pauseTomorrow, resume
    case leadTime, lead(Int)
    case testTakeover, refresh, openConfig, quit
}

final class MenuViewModel: ObservableObject {
    @Published var snapshot = MenuSnapshot()
    @Published var highlighted: MenuRowID?
    @Published var leadExpanded = false

    var onAction: (MenuAction) -> Void = { _ in }

    var rows: [MenuRowID] {
        var r: [MenuRowID] = []
        if snapshot.authExpired { r.append(.reauth) }
        r += snapshot.isPaused ? [.resume] : [.pauseHour, .pauseTomorrow]
        r.append(.leadTime)
        if leadExpanded { r += MenuSnapshot.leadChoices.map { .lead($0) } }
        r += [.testTakeover, .refresh, .openConfig, .quit]
        return r
    }

    /// Moves the highlight by `delta`, wrapping like a native menu.
    func move(_ delta: Int) {
        let r = rows
        guard !r.isEmpty else { return }
        guard let cur = highlighted, let i = r.firstIndex(of: cur) else {
            highlighted = delta >= 0 ? r.first : r.last
            return
        }
        highlighted = r[(i + delta + r.count) % r.count]
    }

    func activateHighlighted() {
        if let h = highlighted { activate(h) }
    }

    func setLeadExpanded(_ expanded: Bool) {
        leadExpanded = expanded
        if !expanded, case .lead = highlighted { highlighted = .leadTime }
    }

    func activate(_ row: MenuRowID) {
        switch row {
        case .leadTime:      setLeadExpanded(!leadExpanded)
        case .lead(let m):
            setLeadExpanded(false)
            highlighted = .leadTime
            onAction(.setLead(m))
        case .reauth:        onAction(.reauth)
        case .pauseHour:     onAction(.pauseHour)
        case .pauseTomorrow: onAction(.pauseTomorrow)
        case .resume:        onAction(.resume)
        case .testTakeover:  onAction(.testTakeover)
        case .refresh:       onAction(.refresh)
        case .openConfig:    onAction(.openConfig)
        case .quit:          onAction(.quit)
        }
    }

    /// Called when the panel closes, so it reopens clean.
    func reset() {
        highlighted = nil
        leadExpanded = false
    }
}
