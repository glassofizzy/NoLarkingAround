import AppKit
import Foundation
import SwiftUI

// Phase 1 entry point: verification CLI. The menu-bar agent and takeover window
// are added in later phases; `--print-agenda` exists so classification, room
// parsing and clash detection can be checked against the real calendar first.

let args = Array(CommandLine.arguments.dropFirst())

func has(_ flag: String) -> Bool { args.contains(flag) }
func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let config = Config.load()
let client = LarkClient(cliPath: config.larkCLIPath)
let store = EventStore(client: client, config: config)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - --print-agenda

func printAgenda(explain: String?) {
    do {
        let me = try store.resolveIdentity()
        print("identity: \(me.name ?? "?") (\(me.openID ?? "?"))")
        print("primary calendar: \(try store.resolvePrimaryCalendarID())")
    } catch let e as LarkError {
        fail(e.description)
    } catch {
        fail(String(describing: error))
    }

    let now = Date()
    let horizon = now.addingTimeInterval(18 * 3600)

    let events: [LarkEvent]
    do {
        events = try store.fetchAgenda(from: now, to: horizon)
    } catch let e as LarkError {
        fail(e.description)
    } catch {
        fail(String(describing: error))
    }

    print("window: now → +18h   events: \(events.count)")

    if let target = explain {
        guard let hit = events.first(where: { $0.eventID == target }) else {
            fail("event_id \(target) not in the current window")
        }
        do {
            let attendees = try store.fetchAttendees(for: hit)
            print("\n--- raw attendees for \(hit.summary ?? "?") ---")
            for a in attendees {
                print("  type=\(a.type ?? "?")  rsvp=\(a.rsvpStatus ?? "?")  "
                    + "organizer=\(a.isOrganizer.map(String.init) ?? "-")  "
                    + "id=\(a.userID ?? "-")  name=\(a.displayName ?? "-")")
            }
            let room = MeetingAlert.parseRoom(attendees: attendees,
                                              locationName: hit.location?.name,
                                              priority: config.roomPriority)
            print("  parsed room slab: \(room.slab ?? "<none>")")
            print("  parsed floor    : \(room.floor ?? "<none>")")
        } catch let e as LarkError {
            fail(e.description)
        } catch {
            fail(String(describing: error))
        }
        return
    }

    // nil window: look up attendees for every event, not just imminent ones.
    let classified = store.classify(events: events, now: now, attendeeWindow: nil)

    let timeFmt = DateFormatter()
    timeFmt.dateFormat = "EEE HH:mm"
    timeFmt.locale = Locale(identifier: "en_GB")

    var alerting = 0
    for item in classified {
        let when = item.event.start.map { timeFmt.string(from: $0) } ?? "??"
        let title = item.event.summary ?? "<untitled>"

        switch item.verdict {
        case .alert(let failOpen):
            alerting += 1
            print("\nALERT  \(when)  \(title)\(failOpen ? "   [fail-open: attendee lookup failed]" : "")")
            guard let a = store.buildAlert(for: item) else {
                print("       !! could not build view model")
                continue
            }
            print("       time      : \(a.timeRange) · \(a.durationLabel.uppercased()) · \(a.attendanceLabel.uppercased())")
            print("       room      : \(a.roomSlab ?? "<none>")")
            print("       floor     : \(a.floorLabel ?? "<none>")")
            print("       host      : \(a.hostName) [\(a.hostTag)]")
            print("       with      : \(a.participantNames.isEmpty ? "<none>" : a.participantNames.joined(separator: ", "))"
                + (a.moreLabel.map { "  \($0)" } ?? ""))
            print("       join      : \(a.joinURL?.absoluteString ?? "<none — button hidden>")")
            print("       clash     : \(a.clashLabel ?? "<none>")")
            let c = a.countdown(now: now)
            print("       countdown : \(c.value) \(c.unit)   wall \(String(format: "%.1f", a.progressPercent(now: now, leadMinutes: config.leadMinutes)))%")
            print("       event_id  : \(a.eventID)")

        case .skip(let reason):
            print("\nskip   \(when)  \(title)")
            print("       reason    : \(reason)")
        }
    }

    print("\n\(alerting) of \(classified.count) events would take over the screen.")
}

// MARK: - --test-overlay

/// Renders the takeover immediately with synthetic data, for side-by-side
/// comparison against the reference design.
func testOverlay(showJoin: Bool, showClash: Bool, minutesUntil: Double) {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let start = Date().addingTimeInterval(minutesUntil * 60)
    let sample = MeetingAlert(
        eventID: "sample",
        title: "Design review",
        start: start,
        end: start.addingTimeInterval(3600),
        timeRange: "12:00 – 13:00",
        durationLabel: "60 min",
        attendanceLabel: "5 invited",
        roomSlab: "Hinoki room",
        floorLabel: "level 2, north wing",
        hostName: "John Ellis",
        hostTag: "HOST",
        hostIsMe: false,
        participantNames: ["Dan", "Priya"],
        moreLabel: "+2 more",
        joinURL: showJoin ? URL(string: "https://vc-sg.larksuite.com/j/000000000") : nil,
        clashLabel: showClash ? "1:1 with Sam · 12:30 – 13:00" : nil
    )

    let controller = TakeoverController()
    let delegate = TestDelegate(controller: controller, alert: sample,
                                leadMinutes: config.leadMinutes)
    app.delegate = delegate
    app.run()
}

final class TestDelegate: NSObject, NSApplicationDelegate {
    let controller: TakeoverController
    let alert: MeetingAlert
    let leadMinutes: Int

    init(controller: TakeoverController, alert: MeetingAlert, leadMinutes: Int) {
        self.controller = controller
        self.alert = alert
        self.leadMinutes = leadMinutes
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.show(alert: alert, leadMinutes: leadMinutes) { action in
            switch action {
            case .join(let url):
                print("join -> \(url.absoluteString)")
            case .dismiss:
                print("dismiss")
            case .snoozeUntilStart:
                print("snooze until start")
            }
            NSApp.terminate(nil)
        }
        if FontLoader.shared.didFallBack {
            FileHandle.standardError.write(
                "warning: bundled fonts did not load; using system fallback\n".data(using: .utf8)!)
        }
    }
}

/// Renders the takeover offscreen to a PNG at a given size. Used to check design
/// fidelity without hijacking the user's actual display.
@available(macOS 13.0, *)
@MainActor
func snapshot(to path: String, width: CGFloat, height: CGFloat,
              showJoin: Bool, showClash: Bool, minutesUntil: Double,
              leadMinutes: Int, scale: CGFloat) {
    FontLoader.shared.register()

    let start = Date().addingTimeInterval(minutesUntil * 60)
    let sample = MeetingAlert(
        eventID: "sample",
        title: "Design review",
        start: start,
        end: start.addingTimeInterval(3600),
        timeRange: "12:00 – 13:00",
        durationLabel: "60 min",
        attendanceLabel: "5 invited",
        roomSlab: "Hinoki room",
        floorLabel: "level 2, north wing",
        hostName: "John Ellis",
        hostTag: "HOST",
        hostIsMe: false,
        participantNames: ["Dan", "Priya"],
        moreLabel: "+2 more",
        joinURL: showJoin ? URL(string: "https://vc-sg.larksuite.com/j/000000000") : nil,
        clashLabel: showClash ? "1:1 with Sam · 12:30 – 13:00" : nil
    )

    let view = TakeoverView(alert: sample, leadMinutes: leadMinutes) { _ in }
        .frame(width: width, height: height)
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let cg = renderer.cgImage else { fail("could not render snapshot") }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fail("could not encode PNG")
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        fail("could not write \(path): \(error)")
    }
    print("wrote \(path)  \(cg.width)x\(cg.height)")
    if FontLoader.shared.didFallBack {
        print("warning: bundled fonts did not load; system fallback was used")
    }
}

/// Renders the status pill above the dropdown panel, with sample meetings, so the
/// menu design can be checked without clicking the real menu bar.
@available(macOS 13.0, *)
@MainActor
func snapshotMenu(to path: String, paused: Bool, authExpired: Bool, expanded: Bool,
                  leadMinutes: Int, scale: CGFloat) {
    FontLoader.shared.register()

    let now = Date()
    let cal = Calendar.current
    func at(_ dayOffset: Int, _ h: Int, _ m: Int) -> Date {
        let day = cal.date(byAdding: .day, value: dayOffset, to: now) ?? now
        return cal.date(bySettingHour: h, minute: m, second: 0, of: day) ?? now
    }
    func meeting(_ title: String, _ start: Date) -> MeetingAlert {
        MeetingAlert(eventID: title, title: title, start: start,
                     end: start.addingTimeInterval(1800), timeRange: "", durationLabel: "",
                     attendanceLabel: "", roomSlab: nil, floorLabel: nil, hostName: "",
                     hostTag: "", hostIsMe: false, participantNames: [], moreLabel: nil,
                     joinURL: nil, clashLabel: nil)
    }
    // Sample day relative to "now" so the header reads TODAY / TOMORROW.
    let upcoming = [
        meeting("Payment x Accomm Biweekly", now.addingTimeInterval(67 * 60)),
        meeting("Google & Expedia UGC Accom Content", now.addingTimeInterval(3 * 3600)),
        meeting("GHA Multi-Rate Project - Weekly Sync", at(1, 9, 30)),
    ]

    let model = MenuViewModel()
    model.snapshot = MenuSnapshot.make(
        upcoming: upcoming, now: now, authExpired: authExpired,
        errorText: nil, isPaused: paused, leadMinutes: leadMinutes)
    model.leadExpanded = expanded
    model.highlighted = expanded ? .lead(leadMinutes == 5 ? 3 : 5) : .pauseTomorrow

    let pill = PillState.make(next: upcoming.first, now: now,
                              authExpired: authExpired, isPaused: paused)
    let view = VStack(alignment: .leading, spacing: 10) {
        StatusPillView(state: pill)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.ground)
        MenuPanelView(model: model)
            .padding(.horizontal, 8)
    }
    .padding(.bottom, 10)
    .frame(width: MenuPanelView.width + MenuPanelView.shadowOffset + 16)
    .background(DS.paper)

    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let cg = renderer.cgImage else { fail("could not render menu snapshot") }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fail("could not encode PNG")
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        fail("could not write \(path): \(error)")
    }
    print("wrote \(path)  \(cg.width)x\(cg.height)")
    if FontLoader.shared.didFallBack {
        print("warning: bundled fonts did not load; system fallback was used")
    }
}

// MARK: - Dispatch

if has("--selftest") {
    exit(SelfTest.run(config: config) == 0 ? 0 : 1)
}

if has("--print-agenda") {
    printAgenda(explain: value(after: "--explain"))
    exit(0)
}

if let out = value(after: "--snapshot") {
    if #available(macOS 13.0, *) {
        // ImageRenderer is @MainActor; top-level code runs on the main thread but
        // is not actor-isolated, so assert the isolation explicitly.
        MainActor.assumeIsolated {
        snapshot(
            to: out,
            width: CGFloat(Double(value(after: "--width") ?? "") ?? 1440),
            height: CGFloat(Double(value(after: "--height") ?? "") ?? 900),
            showJoin: !has("--no-vc"),
            showClash: !has("--no-clash"),
            minutesUntil: Double(value(after: "--minutes") ?? "") ?? 3,
            leadMinutes: Int(value(after: "--lead") ?? "") ?? config.leadMinutes,
            scale: CGFloat(Double(value(after: "--scale") ?? "") ?? 2)
        )
        }
        exit(0)
    }
    fail("--snapshot needs macOS 13+")
}

if let out = value(after: "--snapshot-menu") {
    if #available(macOS 13.0, *) {
        MainActor.assumeIsolated {
            snapshotMenu(
                to: out,
                paused: has("--paused"),
                authExpired: has("--auth-expired"),
                expanded: has("--expanded"),
                leadMinutes: Int(value(after: "--lead") ?? "") ?? config.leadMinutes,
                scale: CGFloat(Double(value(after: "--scale") ?? "") ?? 2)
            )
        }
        exit(0)
    }
    fail("--snapshot-menu needs macOS 13+")
}

if has("--test-overlay") {
    testOverlay(
        showJoin: !has("--no-vc"),
        showClash: !has("--no-clash"),
        minutesUntil: Double(value(after: "--minutes") ?? "") ?? 3
    )
    exit(0)
}

if !has("--help") && !has("-h") {
    // Default mode: run the menu-bar agent.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // no dock icon
    let delegate = AgentDelegate(config: config)
    app.delegate = delegate
    app.run()
    exit(0)
}

print("""
No Larking Around — full-screen Lark meeting takeover

  --selftest                  run the alert-lifecycle checks
  --print-agenda              classify the next 18h and show derived design fields
  --print-agenda --explain ID dump the raw attendee response for one event
  --test-overlay              render the takeover now with synthetic data
      --no-vc                 hide the Join button (no meeting link)
      --no-clash              hide the CLASHES WITH slab
      --minutes N             pretend the meeting starts in N minutes
  --snapshot PATH             render offscreen to a PNG (design QA)
      --width N --height N    snapshot size, default 1440x900
      --lead N --scale N      wall lead window and pixel scale
  --snapshot-menu PATH        render the status pill + dropdown panel to a PNG
      --paused                show the paused state
      --auth-expired          show the Lark sign-in expired state
      --expanded              show the lead-time options expanded
      --lead N --scale N      current lead time and pixel scale

With no flags, runs as a menu-bar agent.
""")
