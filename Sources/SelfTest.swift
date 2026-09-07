import AppKit
import Foundation

/// Records presentations instead of creating windows, so the alert lifecycle can be
/// driven against a virtual clock.
final class FakePresenter: TakeoverPresenting {
    var shown: [(title: String, at: Date)] = []
    var tornDown = 0
    private var handler: ((TakeoverAction) -> Void)?
    private(set) var isShowing = false
    var clock: () -> Date = { Date() }

    func show(alert: MeetingAlert, leadMinutes: Int, soundName: String?,
              onAction: @escaping (TakeoverAction) -> Void) {
        isShowing = true
        handler = onAction
        shown.append((alert.title, clock()))
    }

    func teardown() {
        if isShowing { tornDown += 1 }
        isShowing = false
        handler = nil
    }

    /// Simulates the user clicking a button on the takeover.
    func act(_ action: TakeoverAction) {
        let h = handler
        teardown()
        h?(action)
    }
}

enum SelfTest {
    static func run(config baseConfig: Config) -> Int {
        var failures = 0

        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                print("  ok    \(label)")
            } else {
                failures += 1
                print("  FAIL  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
            }
        }

        // A meeting starting at T+180s, lead 3 min => lead fires exactly at T.
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var config = baseConfig
        config.leadMinutes = 3
        config.alsoAtStart = true
        config.autoClearSeconds = 120
        config.quietHours = nil

        let start = t0.addingTimeInterval(180)
        let sample = MeetingAlert(
            eventID: "evt", title: "Metric Tree",
            start: start, end: start.addingTimeInterval(1800),
            timeRange: "10:00 – 10:30", durationLabel: "30 min",
            attendanceLabel: "2 invited",
            roomSlab: nil, floorLabel: nil,
            hostName: "You", hostTag: "YOU HOST", hostIsMe: true,
            participantNames: ["Dan Whitfield"], moreLabel: nil,
            joinURL: URL(string: "https://vc-sg.larksuite.com/j/1"), clashLabel: nil
        )

        // Every scheduler built here records Join URLs rather than opening them.
        let opened = Box<[URL]>([])

        func makeScheduler() -> (AlertScheduler, FakePresenter, Box<Date>) {
            let now = Box(t0.addingTimeInterval(-60))
            let presenter = FakePresenter()
            presenter.clock = { now.value }
            let store = EventStore(
                client: LarkClient(cliPath: config.larkCLIPath), config: config)
            let s = AlertScheduler(store: store, takeover: presenter, config: config)
            s.clock = { now.value }
            s.alertsOverride = [sample]
            s.openURL = { opened.value.append($0) }
            return (s, presenter, now)
        }

        print("\n1. lead alert timing")
        do {
            let (s, p, now) = makeScheduler()
            now.value = t0.addingTimeInterval(-1)
            s.evaluate()
            check("no takeover 1s before T-3", p.shown.isEmpty)
            now.value = t0
            s.evaluate()
            check("takeover at exactly T-3", p.shown.count == 1,
                  "shown=\(p.shown.count)")
        }

        print("\n2. Dismiss kills the occurrence — no at-start re-fire")
        do {
            let (s, p, now) = makeScheduler()
            now.value = t0
            s.evaluate()
            p.act(.dismiss)
            now.value = start
            s.evaluate()
            now.value = start.addingTimeInterval(30)
            s.evaluate()
            check("still only the one takeover", p.shown.count == 1,
                  "shown=\(p.shown.count)")
        }

        print("\n3. Join opens the link and suppresses the at-start alert")
        do {
            let (s, p, now) = makeScheduler()
            opened.value = []
            now.value = t0
            s.evaluate()
            p.act(.join(URL(string: "https://vc-sg.larksuite.com/j/1")!))
            check("join handed the URL to the opener", opened.value.count == 1,
                  "opened=\(opened.value.count)")
            check("opened the meeting URL",
                  opened.value.first?.absoluteString == "https://vc-sg.larksuite.com/j/1")
            now.value = start
            s.evaluate()
            check("no second takeover after joining", p.shown.count == 1,
                  "shown=\(p.shown.count)")
        }

        print("\n4. Snooze until it starts re-shows at start")
        do {
            let (s, p, now) = makeScheduler()
            now.value = t0
            s.evaluate()
            p.act(.snoozeUntilStart)
            now.value = t0.addingTimeInterval(60)
            s.evaluate()
            check("stays hidden while snoozed", p.shown.count == 1,
                  "shown=\(p.shown.count)")
            now.value = start
            s.evaluate()
            check("re-shows at start time", p.shown.count == 2,
                  "shown=\(p.shown.count)")
        }

        print("\n5. Ignored takeover auto-clears after start")
        do {
            let (s, p, now) = makeScheduler()
            now.value = t0
            s.evaluate()
            check("takeover is up", p.isShowing)
            now.value = start.addingTimeInterval(119)
            s.evaluate()
            check("still up 119s after start", p.isShowing)
            now.value = start.addingTimeInterval(121)
            s.evaluate()
            check("cleared 121s after start", !p.isShowing)
        }

        print("\n6. Pause suppresses alerts")
        do {
            let (s, p, now) = makeScheduler()
            s.pause(until: t0.addingTimeInterval(3600))
            now.value = t0
            s.evaluate()
            check("nothing shown while paused", p.shown.isEmpty)
            s.resume()
            s.evaluate()
            check("shows once resumed", p.shown.count == 1)
        }

        print("\n7. Waking up long after the meeting fires nothing")
        do {
            let (s, p, now) = makeScheduler()
            now.value = start.addingTimeInterval(3600)   // slept through it
            s.evaluate()
            check("no stale takeover on wake", p.shown.isEmpty,
                  "shown=\(p.shown.count)")
        }

        print("\n8. Quiet hours")
        do {
            var quiet = config
            quiet.quietHours = Config.QuietHours(start: "00:00", end: "23:59")
            let now = Box(t0)
            let presenter = FakePresenter()
            presenter.clock = { now.value }
            let store = EventStore(
                client: LarkClient(cliPath: quiet.larkCLIPath), config: quiet)
            let s = AlertScheduler(store: store, takeover: presenter, config: quiet)
            s.clock = { now.value }
            s.alertsOverride = [sample]
            s.openURL = { opened.value.append($0) }
            s.evaluate()
            check("nothing during quiet hours", presenter.shown.isEmpty)
        }

        print("\n9. Ignore-keyword matching is whole-word")
        do {
            check("'hold' does not match '[Placeholder] Daily GHA'",
                  !EventStore.matchesWord("hold", in: "[Placeholder] Daily GHA - Price Accuracy"))
            check("'hold' matches 'Hold for review'",
                  EventStore.matchesWord("hold", in: "Hold for review"))
            check("'lunch' matches 'Lunch '",
                  EventStore.matchesWord("lunch", in: "Lunch "))
            check("'focus' does not match 'Focusing session'",
                  !EventStore.matchesWord("focus", in: "Focusing session"))
        }

        print("\n10. Room parsing")
        do {
            func room(_ name: String) -> (slab: String?, floor: String?) {
                MeetingAlert.parseRoom(
                    attendees: [FakeRoom.make(name)], locationName: nil)
            }
            let a = room("CPT-L10-A13(2) SG - Capital Tower")
            check("slab CPT-L10-A13(2)", a.slab == "CPT-L10-A13(2)", "got \(a.slab ?? "nil")")
            check("floor SG · Capital Tower", a.floor == "SG · Capital Tower",
                  "got \(a.floor ?? "nil")")
            let b = room("NTC-L05-D4(4) ID - Green Office Park")
            check("slab NTC-L05-D4(4)", b.slab == "NTC-L05-D4(4)", "got \(b.slab ?? "nil")")
            check("floor ID · Green Office Park", b.floor == "ID · Green Office Park",
                  "got \(b.floor ?? "nil")")
            let c = MeetingAlert.parseRoom(attendees: [],
                                           locationName: "L10 A3 & A4 for those in SG")
            check("falls back to free-text location",
                  c.slab == "L10 A3 & A4 for those in SG" && c.floor == nil)
            let d = MeetingAlert.parseRoom(attendees: [], locationName: nil)
            check("no room and no location hides both", d.slab == nil && d.floor == nil)
        }

        print("\n11. Countdown and wall")
        do {
            check("3 min reads '3 mins to'",
                  sample.countdown(now: start.addingTimeInterval(-180)).unit == "mins to")
            check("1 min reads '1 min to'",
                  sample.countdown(now: start.addingTimeInterval(-60)).value == "1")
            check("under a minute reads '<1'",
                  sample.countdown(now: start.addingTimeInterval(-30)).value == "<1")
            let atLead = sample.progressPercent(now: start.addingTimeInterval(-180),
                                                leadMinutes: 3)
            check("wall floors at 6% at T-lead", abs(atLead - 6) < 0.01,
                  "got \(atLead)")
            let atStart = sample.progressPercent(now: start, leadMinutes: 3)
            check("wall reaches 100% at start", abs(atStart - 100) < 0.01,
                  "got \(atStart)")
        }

        print("\n12. Partial config keeps defaults for absent keys")
        do {
            let json = #"{"leadMinutes": 7}"#.data(using: .utf8)!
            let c = try? JSONDecoder().decode(Config.self, from: json)
            check("leadMinutes read from file", c?.leadMinutes == 7)
            check("autoClearSeconds keeps its default", c?.autoClearSeconds == 120)
            check("ignoreKeywords keeps its default", (c?.ignoreKeywords.count ?? 0) > 0)
        }

        print("\n13. Recurring-instance attendee id order")
        do {
            // The instance must always be asked first: a booked room is attached to
            // the instance, and the master would answer without it.
            let virtualInstance = FakeEvent.make(
                eventID: "abc_1788514200", recurringEventID: "abc_0", isException: false)
            check("non-exception tries the instance first, master as fallback",
                  EventStore.attendeeIDCandidates(for: virtualInstance)
                      == ["abc_1788514200", "abc_0"])

            let modifiedInstance = FakeEvent.make(
                eventID: "def_1788512400", recurringEventID: "def_0", isException: true)
            check("exception tries the instance first too",
                  EventStore.attendeeIDCandidates(for: modifiedInstance)
                      == ["def_1788512400", "def_0"])

            check("master is never asked before the instance",
                  EventStore.attendeeIDCandidates(for: virtualInstance).first
                      == "abc_1788514200")

            let single = FakeEvent.make(
                eventID: "ghi_0", recurringEventID: nil, isException: false)
            check("non-recurring uses one id",
                  EventStore.attendeeIDCandidates(for: single) == ["ghi_0"])

            let selfRef = FakeEvent.make(
                eventID: "jkl_0", recurringEventID: "jkl_0", isException: false)
            check("master equal to instance is not duplicated",
                  EventStore.attendeeIDCandidates(for: selfRef) == ["jkl_0"])
        }

        print("\n14. Child PATH repair for lark-cli (node shebang)")
        do {
            // launchd hands processes this PATH, which has no /usr/local/bin.
            let launchd = "/usr/bin:/bin:/usr/sbin:/sbin"
            let repaired = LarkClient.childPATH(
                inherited: launchd, cliPath: "/opt/homebrew/bin/lark-cli")
            let dirs = repaired.split(separator: ":").map(String.init)
            check("includes /usr/local/bin where node lives",
                  dirs.contains("/usr/local/bin"))
            check("includes the CLI's own directory",
                  dirs.contains("/opt/homebrew/bin"))
            check("preserves the inherited entries",
                  dirs.contains("/usr/bin") && dirs.contains("/bin"))
            check("no duplicate entries", dirs.count == Set(dirs).count,
                  "\(dirs.count) entries, \(Set(dirs).count) unique")
            check("node dirs come before the inherited PATH",
                  (dirs.firstIndex(of: "/usr/local/bin") ?? .max)
                      < (dirs.firstIndex(of: "/usr/bin") ?? .max))
            // Empty inherited PATH must still yield a usable one.
            let bare = LarkClient.childPATH(inherited: nil, cliPath: "/x/lark-cli")
            check("survives an absent inherited PATH",
                  bare.contains("/usr/local/bin") && bare.contains("/bin"))
        }

        print("\n15. Guest list derivation (what rendered as '1 INVITED', no Adit)")
        do {
            let me = "ou_me"
            let event = FakeEvent.make(
                eventID: "x_1", recurringEventID: nil, isException: false,
                organizerID: me, organizerName: "Test User")
            let attendees = [
                FakeHuman.make(id: me, name: "Test User"),
                FakeHuman.make(id: "ou_dan", name: "Dan Whitfield"),
            ]
            let a = MeetingAlert.make(event: event, attendees: attendees,
                                      myOpenID: me, myDisplayName: "Test User",
                                      clash: nil)
            check("counts both humans as invited", a?.attendanceLabel == "2 invited",
                  "got \(a?.attendanceLabel ?? "nil")")
            check("shows the other person", a?.participantNames == ["Dan Whitfield"],
                  "got \(a?.participantNames ?? [])")
            check("host reads You", a?.hostName == "You" && a?.hostTag == "YOU HOST")
            check("no overflow pill for one guest", a?.moreLabel == nil)

            // An empty attendee list is what the 30-minute window used to produce.
            let hollow = MeetingAlert.make(event: event, attendees: [],
                                           myOpenID: me, myDisplayName: "Test User",
                                           clash: nil)
            check("empty attendees is detectably wrong, not silently plausible",
                  hollow?.attendanceLabel == "1 invited"
                      && hollow?.participantNames.isEmpty == true)

            // Someone else hosting: they must appear as the host, not as a guest.
            let theirs = FakeEvent.make(
                eventID: "y_1", recurringEventID: nil, isException: false,
                organizerID: "ou_priya", organizerName: "Priya Raman")
            let b = MeetingAlert.make(
                event: theirs,
                attendees: [FakeHuman.make(id: me, name: "Test User"),
                            FakeHuman.make(id: "ou_priya", name: "Priya Raman"),
                            FakeHuman.make(id: "ou_a", name: "Alex Okonjo"),
                            FakeHuman.make(id: "ou_b", name: "Rin Nakamura"),
                            FakeHuman.make(id: "ou_c", name: "Sam Ellery")],
                myOpenID: me, myDisplayName: "Test User", clash: nil)
            check("host is the organiser", b?.hostName == "Priya Raman",
                  "got \(b?.hostName ?? "nil")")
            check("caps guests at two", b?.participantNames.count == 2)
            check("overflow counts the rest", b?.moreLabel == "+1 more",
                  "got \(b?.moreLabel ?? "nil")")
            check("host and self excluded from guests",
                  !(b?.participantNames.contains("Priya Raman") ?? true)
                      && !(b?.participantNames.contains("Test User") ?? true))
        }

        print("\n16. Attendee cache expiry (the stale room / stale guest list)")
        do {
            let fetched = Date(timeIntervalSince1970: 1_800_000_000)
            let ttl: TimeInterval = 300

            check("fresh success is reused",
                  !EventStore.isEntryStale(fetchedAt: fetched, succeeded: true,
                                           now: fetched.addingTimeInterval(299),
                                           successTTL: ttl))
            check("success expires at the TTL",
                  EventStore.isEntryStale(fetchedAt: fetched, succeeded: true,
                                          now: fetched.addingTimeInterval(300),
                                          successTTL: ttl))
            // A room booked after the first poll must appear before the meeting.
            check("a room booked 90 min later is picked up",
                  EventStore.isEntryStale(fetchedAt: fetched, succeeded: true,
                                          now: fetched.addingTimeInterval(5400),
                                          successTTL: ttl))
            check("a cached failure is retried within a minute",
                  EventStore.isEntryStale(fetchedAt: fetched, succeeded: false,
                                          now: fetched.addingTimeInterval(61),
                                          successTTL: ttl))
            check("a cached failure is not retried every second",
                  !EventStore.isEntryStale(fetchedAt: fetched, succeeded: false,
                                           now: fetched.addingTimeInterval(30),
                                           successTTL: ttl))
            check("failures expire sooner than successes",
                  EventStore.failureTTL < ttl)
        }

        print(failures == 0
            ? "\nall checks passed"
            : "\n\(failures) check(s) FAILED")
        return failures
    }
}

/// Mutable box so the virtual clock can be shared with escaping closures.
final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Builds a resource-type attendee from JSON, since LarkAttendee is decode-only.
enum FakeRoom {
    static func make(_ name: String) -> LarkAttendee {
        let json = """
        {"type":"resource","display_name":\(jsonString(name)),"rsvp_status":"accept"}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(LarkAttendee.self, from: json)
    }

    private static func jsonString(_ s: String) -> String {
        let data = try! JSONEncoder().encode(s)
        return String(data: data, encoding: .utf8)!
    }
}


/// Builds a LarkEvent from JSON, since the wire types are decode-only.
enum FakeEvent {
    static func make(eventID: String, recurringEventID: String?,
                     isException: Bool,
                     organizerID: String? = nil,
                     organizerName: String? = nil) -> LarkEvent {
        let rec = recurringEventID.map { "\"\($0)\"" } ?? "null"
        let org = organizerID == nil ? "null" : """
            {"user_id": "\(organizerID!)", "display_name": "\(organizerName ?? "")"}
            """
        let json = """
        {
          "event_id": "\(eventID)",
          "summary": "test",
          "event_organizer": \(org),
          "start_time": {"datetime": "2026-09-04T17:30:00+08:00", "timezone": "Asia/Singapore"},
          "end_time": {"datetime": "2026-09-04T18:15:00+08:00", "timezone": "Asia/Singapore"},
          "recurring_event_id": \(rec),
          "is_exception": \(isException)
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(LarkEvent.self, from: json)
    }
}


/// Builds a human attendee from JSON, since the wire types are decode-only.
enum FakeHuman {
    static func make(id: String, name: String) -> LarkAttendee {
        let json = """
        {"type":"user","user_id":"\(id)","display_name":"\(name)","rsvp_status":"accept"}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(LarkAttendee.self, from: json)
    }
}
