import Foundation

/// Why an event will or will not produce a takeover.
enum Verdict {
    /// `failOpen` means the attendee lookup errored and we chose to alert anyway.
    case alert(failOpen: Bool)
    case skip(String)

    var isAlert: Bool {
        if case .alert = self { return true }
        return false
    }
}

struct ClassifiedEvent {
    let event: LarkEvent
    let verdict: Verdict
    let attendees: [LarkAttendee]
    let clash: LarkEvent?
}

/// Reads the Lark calendar, decides which events deserve a takeover, and derives
/// the design's view model. Holds an attendee cache so a 60s poll does not re-fetch
/// the same event's attendee list over and over.
final class EventStore {
    private let client: LarkClient
    private var config: Config

    private(set) var myOpenID: String?
    private(set) var myDisplayName: String?
    private(set) var primaryCalendarID: String?
    private(set) var authOK = false

    /// A cached lookup. `attendees == nil` records a failure so a broken endpoint
    /// is not hammered, but expires quickly so a transient error does not pin the
    /// fail-open path for long.
    private struct AttendeeEntry {
        let fetchedAt: Date
        let attendees: [LarkAttendee]?
    }
    /// event_id -> entry. Pruned when the agenda no longer contains the key.
    private var attendeeCache: [String: AttendeeEntry] = [:]
    static let failureTTL: TimeInterval = 60

    init(client: LarkClient, config: Config) {
        self.client = client
        self.config = config
    }

    func update(config: Config) { self.config = config }

    // MARK: - Identity

    /// `auth status` is the one command that returns a bare object with no
    /// {ok, data} envelope, so it is decoded directly.
    @discardableResult
    func resolveIdentity() throws -> (openID: String?, name: String?) {
        let out = try client.raw(args: ["auth", "status"])
        let status = try JSONDecoder().decode(LarkAuthStatus.self, from: out)
        guard status.isUsable else {
            let detail = status.identities?.user?.tokenStatus ?? "no user identity"
            authOK = false
            throw LarkError.authExpired("token status: \(detail)")
        }
        authOK = true
        myOpenID = status.identities?.user?.openID
        myDisplayName = status.identities?.user?.userName
        return (myOpenID, myDisplayName)
    }

    /// The attendee endpoint only works with the user's own primary calendar id;
    /// the organizer's calendar id returns 194001 no permission.
    @discardableResult
    func resolvePrimaryCalendarID() throws -> String {
        if let id = primaryCalendarID { return id }
        let page = try client.decode(LarkPrimaryCalendars.self,
                                     args: ["calendar", "calendars", "primary"])
        guard let id = page.calendars?.compactMap({ $0.calendar?.calendarID }).first else {
            throw LarkError.badOutput("no primary calendar returned")
        }
        primaryCalendarID = id
        return id
    }

    // MARK: - Fetching

    func fetchAgenda(from: Date, to: Date) throws -> [LarkEvent] {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let events = try client.decode([LarkEvent].self, args: [
            "calendar", "+agenda",
            "--start", f.string(from: from),
            "--end", f.string(from: to),
            "--format", "json",
        ])
        // Drop cache entries for events that have left the window.
        let live = Set(events.map(\.eventID))
        attendeeCache = attendeeCache.filter { live.contains($0.key) }
        return events
    }

    /// Which event id to ask for attendees, in order.
    ///
    /// The instance id always comes first: a booked meeting room is attached to the
    /// specific instance, while the master (`recurring_event_id`) carries only the
    /// series-level guest list. Ordering by `is_exception` was wrong — whenever the
    /// master answered, the room was silently dropped.
    ///
    /// The master is the fallback because a recurring instance that was never
    /// individually modified is virtual, and its instance id returns 193001.
    static func attendeeIDCandidates(for event: LarkEvent) -> [String] {
        guard let master = event.recurringEventID, master != event.eventID else {
            return [event.eventID]
        }
        return [event.eventID, master]
    }

    func fetchAttendees(for event: LarkEvent, now: Date = Date()) throws -> [LarkAttendee] {
        if let entry = attendeeCache[event.eventID], !isStale(entry, now: now) {
            guard let attendees = entry.attendees else {
                throw LarkError.api(code: -1, message: "attendee lookup failed (cached)")
            }
            return attendees
        }

        let calendarID = try resolvePrimaryCalendarID()
        var lastError: Error?
        for candidate in EventStore.attendeeIDCandidates(for: event) {
            do {
                let all = try fetchAttendeePages(calendarID: calendarID, eventID: candidate)
                attendeeCache[event.eventID] = AttendeeEntry(fetchedAt: now, attendees: all)
                return all
            } catch {
                lastError = error
            }
        }
        attendeeCache[event.eventID] = AttendeeEntry(fetchedAt: now, attendees: nil)
        throw lastError ?? LarkError.badOutput("no attendee id candidates")
    }

    private func isStale(_ entry: AttendeeEntry, now: Date) -> Bool {
        EventStore.isEntryStale(
            fetchedAt: entry.fetchedAt,
            succeeded: entry.attendees != nil,
            now: now,
            successTTL: TimeInterval(config.attendeeCacheSeconds))
    }

    /// Pure so the expiry rule can be tested directly. Failures expire far sooner
    /// than successes: a cached failure keeps the fail-open path active, which
    /// means a false takeover, so it must be retried quickly.
    static func isEntryStale(fetchedAt: Date, succeeded: Bool, now: Date,
                             successTTL: TimeInterval) -> Bool {
        let ttl = succeeded ? successTTL : failureTTL
        return now.timeIntervalSince(fetchedAt) >= ttl
    }

    private func fetchAttendeePages(calendarID: String, eventID: String)
        throws -> [LarkAttendee] {

        var all: [LarkAttendee] = []
        var pageToken: String?
        repeat {
            var args = [
                "calendar", "event.attendees", "list",
                "--calendar-id", calendarID,
                "--event-id", eventID,
                "--page-size", "100",
            ]
            if let t = pageToken { args += ["--page-token", t] }
            let page = try client.decode(LarkAttendeePage.self, args: args)
            all += page.items ?? []
            pageToken = (page.hasMore == true) ? page.pageToken : nil
        } while pageToken != nil
        return all
    }

    // MARK: - Classification

    /// `attendeeWindow` limits attendee lookups to events starting within that many
    /// seconds; pass nil to look up every event (used by --print-agenda).
    func classify(events: [LarkEvent], now: Date = Date(), attendeeWindow: TimeInterval?)
        -> [ClassifiedEvent] {

        events.map { event in
            var attendees: [LarkAttendee] = []
            let verdict = decide(event: event, now: now,
                                 attendeeWindow: attendeeWindow, attendees: &attendees)
            return ClassifiedEvent(
                event: event,
                verdict: verdict,
                attendees: attendees,
                clash: verdict.isAlert ? findClash(for: event, in: events) : nil
            )
        }
    }

    private func decide(event: LarkEvent, now: Date,
                        attendeeWindow: TimeInterval?,
                        attendees: inout [LarkAttendee]) -> Verdict {
        guard let start = event.start else { return .skip("no start time") }
        if event.isAllDay { return .skip("all-day event") }
        if event.status == "cancelled" { return .skip("cancelled") }
        if event.selfRSVPStatus == "decline" { return .skip("you declined") }
        if let fb = event.freeBusyStatus, fb != "busy" { return .skip("free/busy is \(fb)") }

        if event.selfRSVPStatus == "needs_action", config.requireAccepted {
            return .skip("you have not accepted (needs_action)")
        }

        let title = event.summary ?? ""
        if let hit = config.ignoreKeywords.first(where: { EventStore.matchesWord($0, in: title) }) {
            return .skip("title matches ignore keyword '\(hit)'")
        }

        guard config.requireOtherAttendees else { return .alert(failOpen: false) }

        // Only spend attendee calls on events that are close enough to matter.
        if let window = attendeeWindow, start.timeIntervalSince(now) > window {
            return .alert(failOpen: false)
        }
        do {
            attendees = try fetchAttendees(for: event, now: now)
        } catch {
            // Fail open: a lookup we cannot perform must never cause a missed meeting.
            return .alert(failOpen: true)
        }

        let others = attendees.filter { a in
            guard a.isHuman else { return false }
            if let id = a.userID, id == myOpenID { return false }
            if let n = a.displayName, let mine = myDisplayName, n == mine { return false }
            return true
        }
        if others.isEmpty { return .skip("solo block — no other attendees") }
        return .alert(failOpen: false)
    }

    /// Whole-word, case-insensitive keyword match. Substring matching was wrong:
    /// "hold" matched inside "[Placeholder] Daily GHA" and silently suppressed a
    /// real meeting.
    static func matchesWord(_ keyword: String, in title: String) -> Bool {
        let k = keyword.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return false }
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: k)
                    + "(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return false }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return re.firstMatch(in: title, options: [], range: range) != nil
    }

    // MARK: - Clash detection

    /// Any other event that overlaps this one and is not declined/all-day/free.
    /// Deliberately includes non-alertable events: a clash with "Lunch" is exactly
    /// the kind of thing the design's CLASHES WITH slab is for.
    func findClash(for event: LarkEvent, in events: [LarkEvent]) -> LarkEvent? {
        guard let start = event.start, let end = event.end else { return nil }
        return events
            .filter { other in
                guard other.eventID != event.eventID else { return false }
                guard !other.isAllDay, other.status != "cancelled" else { return false }
                guard other.selfRSVPStatus != "decline" else { return false }
                if let fb = other.freeBusyStatus, fb != "busy" { return false }
                guard let os = other.start, let oe = other.end else { return false }
                return os < end && start < oe
            }
            .min { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    // MARK: - View model

    /// Must be called off the main thread: it may perform a lark-cli lookup.
    func buildAlert(for classified: ClassifiedEvent) -> MeetingAlert? {
        // Classification can legitimately skip the attendee call; never render a
        // takeover with an empty guest list when the data is available.
        var attendees = classified.attendees
        if attendees.isEmpty {
            attendees = (try? fetchAttendees(for: classified.event)) ?? []
        }
        return MeetingAlert.make(
            event: classified.event,
            attendees: attendees,
            myOpenID: myOpenID,
            myDisplayName: myDisplayName,
            clash: classified.clash
        )
    }
}
