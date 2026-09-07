import Foundation

/// Everything the takeover design needs, and nothing platform-specific.
/// Kept free of AppKit/SwiftUI so an iOS port is view code only.
struct MeetingAlert: Equatable {
    let eventID: String
    let title: String
    let start: Date
    let end: Date

    /// "12:00 – 13:00", always in the Mac's local timezone.
    let timeRange: String
    /// "60 MIN"
    let durationLabel: String
    /// "5 INVITED"
    let attendanceLabel: String

    /// Room slab, e.g. "CPT-L10-A13(2)". Nil hides the slab and floor line.
    let roomSlab: String?
    /// Floor line, e.g. "SG · Capital Tower".
    let floorLabel: String?

    let hostName: String
    let hostTag: String
    let hostIsMe: Bool

    /// At most 2, per the design.
    let participantNames: [String]
    /// "+3 more", or nil when nothing overflows.
    let moreLabel: String?

    /// Nil hides the Join button entirely (not disabled — absent).
    let joinURL: URL?

    /// "1:1 with Sam · 12:30 – 13:00", or nil when nothing overlaps.
    let clashLabel: String?

    // MARK: Live-derived values

    func minutesUntilStart(now: Date = Date()) -> Double {
        start.timeIntervalSince(now) / 60.0
    }

    /// Design formula: clamp(6, 100, (1 - minutesUntil / leadMinutes) * 100).
    /// Minimum 6% so the yellow fill is always visible.
    func progressPercent(now: Date = Date(), leadMinutes: Int) -> Double {
        let lead = max(1, leadMinutes)
        let raw = (1 - minutesUntilStart(now: now) / Double(lead)) * 100
        return min(100, max(6, raw))
    }

    /// ("3", "mins to") / ("1", "min to") / ("<1", "min to")
    func countdown(now: Date = Date()) -> (value: String, unit: String) {
        let mins = minutesUntilStart(now: now)
        if mins < 1 { return ("<1", "min to") }
        let rounded = Int(mins.rounded())
        return (String(rounded), rounded == 1 ? "min to" : "mins to")
    }
}

// MARK: - Derivation from Lark data

extension MeetingAlert {
    /// Builds the view model. `attendees` may be empty when the lookup failed
    /// (fail-open path) — the screen then simply shows no participant pills.
    static func make(
        event: LarkEvent,
        attendees: [LarkAttendee],
        myOpenID: String?,
        myDisplayName: String?,
        clash: LarkEvent?
    ) -> MeetingAlert? {
        guard let start = event.start, let end = event.end else { return nil }

        let humans = attendees.filter { $0.isHuman }
        let organizerID = event.eventOrganizer?.userID
        let organizerName = event.eventOrganizer?.displayName
        let hostIsMe = organizerID != nil && organizerID == myOpenID

        // Participants: humans minus me, minus the host.
        let participants = humans.filter { a in
            if let id = a.userID {
                if id == myOpenID { return false }
                if let oid = organizerID, id == oid { return false }
            }
            if let name = a.displayName {
                if let mine = myDisplayName, name == mine { return false }
                if let host = organizerName, name == host { return false }
            }
            return true
        }
        let names = participants.compactMap { $0.displayName }.filter { !$0.isEmpty }
        let shown = Array(names.prefix(2))
        let overflow = names.count - shown.count

        let room = parseRoom(attendees: attendees, locationName: event.location?.name)

        return MeetingAlert(
            eventID: event.eventID,
            title: (event.summary?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "Untitled meeting",
            start: start,
            end: end,
            timeRange: formatRange(start: start, end: end),
            durationLabel: formatDuration(start: start, end: end),
            attendanceLabel: "\(max(humans.count, 1)) invited",
            roomSlab: room.slab,
            floorLabel: room.floor,
            hostName: hostIsMe ? "You" : (organizerName ?? "Unknown"),
            hostTag: hostIsMe ? "YOU HOST" : "HOST",
            hostIsMe: hostIsMe,
            participantNames: shown,
            moreLabel: overflow > 0 ? "+\(overflow) more" : nil,
            joinURL: event.vchat?.meetingURL.flatMap(URL.init(string:)),
            clashLabel: clash.flatMap(clashLabel(for:))
        )
    }

    // MARK: Room parsing

    /// Lark room resources are named like "CPT-L10-A13(2) SG - Capital Tower".
    /// Split on " - ", then peel the trailing region code off the head:
    ///   slab  = "CPT-L10-A13(2)"
    ///   floor = "SG · Capital Tower"
    /// With no room resource we fall back to the event's free-text location in the
    /// slab and show no floor line. With neither, both are hidden.
    static func parseRoom(attendees: [LarkAttendee], locationName: String?)
        -> (slab: String?, floor: String?) {

        let rooms = attendees.filter { $0.isRoom }.compactMap { $0.displayName }
        guard let raw = rooms.first?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            let loc = locationName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (loc?.isEmpty == false ? loc : nil, nil)
        }

        var head = raw
        var building: String?
        if let sep = raw.range(of: " - ") {
            head = String(raw[raw.startIndex..<sep.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let tail = String(raw[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
            building = tail.isEmpty ? nil : tail
        }

        // Peel a trailing 2-3 letter region code ("SG", "ID", "VN") off the head.
        var region: String?
        let parts = head.split(separator: " ").map(String.init)
        if parts.count > 1, let last = parts.last,
           last.count >= 2, last.count <= 3,
           last.allSatisfy({ $0.isUppercase && $0.isLetter }) {
            region = last
            head = parts.dropLast().joined(separator: " ")
        }

        let floor = [region, building].compactMap { $0 }.joined(separator: " · ")
        return (head.isEmpty ? raw : head, floor.isEmpty ? nil : floor)
    }

    // MARK: Formatting

    /// Always renders in the Mac's local timezone. Lark events carry their own
    /// timezone (Asia/Jakarta, Asia/Singapore, Asia/Ho_Chi_Minh all appear on this
    /// calendar), and showing those verbatim would be actively misleading.
    static func formatRange(start: Date, end: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_GB")
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }

    static func formatDuration(start: Date, end: Date) -> String {
        let total = max(0, Int(end.timeIntervalSince(start) / 60))
        if total < 60 { return "\(total) min" }
        let hours = total / 60
        let mins = total % 60
        return mins == 0 ? "\(hours) hr" : "\(hours) hr \(mins) min"
    }

    static func clashLabel(for event: LarkEvent) -> String? {
        guard let start = event.start, let end = event.end else { return nil }
        let title = event.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }
        return "\(title) · \(formatRange(start: start, end: end))"
    }
}
