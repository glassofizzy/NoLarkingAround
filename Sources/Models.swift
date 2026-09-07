import Foundation

// MARK: - Calendar event (from `calendar +agenda`)

struct LarkEvent: Decodable {
    struct Stamp: Decodable {
        /// Timed events carry `datetime`; all-day events carry `date` instead.
        let datetime: String?
        let date: String?
        let timezone: String?
    }
    struct Organizer: Decodable {
        let displayName: String?
        let userID: String?
        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case userID = "user_id"
        }
    }
    struct VChat: Decodable {
        let meetingURL: String?
        let vcType: String?
        enum CodingKeys: String, CodingKey {
            case meetingURL = "meeting_url"
            case vcType = "vc_type"
        }
    }
    struct Location: Decodable { let name: String? }

    let eventID: String
    let summary: String?
    let startTime: Stamp
    let endTime: Stamp
    let selfRSVPStatus: String?
    let freeBusyStatus: String?
    let eventOrganizer: Organizer?
    let vchat: VChat?
    let location: Location?
    let recurringEventID: String?
    let status: String?
    /// True when this recurring instance was individually modified, and so exists
    /// as a real event. Virtual (non-exception) instances only resolve via master.
    let isException: Bool?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case summary
        case startTime = "start_time"
        case endTime = "end_time"
        case selfRSVPStatus = "self_rsvp_status"
        case freeBusyStatus = "free_busy_status"
        case eventOrganizer = "event_organizer"
        case vchat, location, status
        case recurringEventID = "recurring_event_id"
        case isException = "is_exception"
    }

    var isAllDay: Bool { startTime.datetime == nil && startTime.date != nil }

    var start: Date? { LarkEvent.parse(startTime) }
    var end: Date? { LarkEvent.parse(endTime) }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ stamp: Stamp) -> Date? {
        if let dt = stamp.datetime {
            if let d = iso.date(from: dt) { return d }
            // Fall back for fractional seconds, which .withInternetDateTime rejects.
            let alt = ISO8601DateFormatter()
            alt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return alt.date(from: dt)
        }
        if let day = stamp.date {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = stamp.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
            return f.date(from: day)
        }
        return nil
    }
}

// MARK: - Attendees (from `calendar event.attendees list`)

struct LarkAttendeePage: Decodable {
    let items: [LarkAttendee]?
    let hasMore: Bool?
    let pageToken: String?

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
        case pageToken = "page_token"
    }
}

struct LarkAttendee: Decodable {
    /// "user" | "resource" (meeting room) | "chat" | "third_party"
    let type: String?
    let displayName: String?
    let rsvpStatus: String?
    let userID: String?
    let isOrganizer: Bool?
    let isOptional: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case displayName = "display_name"
        case rsvpStatus = "rsvp_status"
        case userID = "user_id"
        case isOrganizer = "is_organizer"
        case isOptional = "is_optional"
    }

    var isHuman: Bool { type == "user" }
    var isRoom: Bool { type == "resource" }
}

// MARK: - Primary calendar (from `calendar calendars primary`)

struct LarkPrimaryCalendars: Decodable {
    struct Entry: Decodable {
        struct Calendar: Decodable {
            let calendarID: String?
            let summary: String?
            let type: String?
            enum CodingKeys: String, CodingKey {
                case calendarID = "calendar_id"
                case summary, type
            }
        }
        let calendar: Calendar?
        let userID: String?
        enum CodingKeys: String, CodingKey {
            case calendar
            case userID = "user_id"
        }
    }
    let calendars: [Entry]?
}

// MARK: - Auth status (from `auth status`)

struct LarkAuthStatus: Decodable {
    struct Identities: Decodable {
        struct User: Decodable {
            let status: String?
            let available: Bool?
            let openID: String?
            let userName: String?
            let tokenStatus: String?
            enum CodingKeys: String, CodingKey {
                case status, available
                case openID = "openId"
                case userName, tokenStatus
            }
        }
        let user: User?
    }
    let identities: Identities?

    var isUsable: Bool {
        guard let u = identities?.user else { return false }
        return u.available == true && u.tokenStatus == "valid"
    }
}
