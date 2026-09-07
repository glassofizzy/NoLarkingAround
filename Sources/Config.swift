import Foundation

/// User-editable settings, stored at ~/.config/inyourlark/config.json.
/// Missing keys fall back to these defaults, so a partial file is valid.
struct Config: Codable {
    var leadMinutes: Int = 3
    var alsoAtStart: Bool = true
    var autoClearSeconds: Int = 120
    var pollSeconds: Int = 60
    var requireOtherAttendees: Bool = true
    /// When true, events you have not answered (`needs_action`) are skipped.
    /// Set false to also be alerted about meetings you forgot to RSVP to.
    var requireAccepted: Bool = true
    /// How long an attendee list stays cached. Rooms and guests can change
    /// after the first poll, so this must expire before the meeting starts.
    var attendeeCacheSeconds: Int = 300
    var ignoreKeywords: [String] = ["lunch", "focus", "block", "hold", "ooo"]
    var quietHours: QuietHours? = QuietHours(start: "22:00", end: "08:00")
    var soundName: String = "Submarine"
    var larkCLIPath: String = "/opt/homebrew/bin/lark-cli"

    struct QuietHours: Codable {
        var start: String
        var end: String
    }

    /// Hand-written so that any subset of keys is a valid config file. The
    /// synthesized Decodable throws keyNotFound on the first missing key, which
    /// made a partial config silently fall back to all defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        let d = Config()
        leadMinutes           = try v(.leadMinutes, d.leadMinutes)
        alsoAtStart           = try v(.alsoAtStart, d.alsoAtStart)
        autoClearSeconds      = try v(.autoClearSeconds, d.autoClearSeconds)
        pollSeconds           = try v(.pollSeconds, d.pollSeconds)
        requireOtherAttendees = try v(.requireOtherAttendees, d.requireOtherAttendees)
        requireAccepted       = try v(.requireAccepted, d.requireAccepted)
        attendeeCacheSeconds  = try v(.attendeeCacheSeconds, d.attendeeCacheSeconds)
        ignoreKeywords        = try v(.ignoreKeywords, d.ignoreKeywords)
        quietHours            = try c.decodeIfPresent(QuietHours.self, forKey: .quietHours)
                                    ?? d.quietHours
        soundName             = try v(.soundName, d.soundName)
        larkCLIPath           = try v(.larkCLIPath, d.larkCLIPath)
    }

    init() {}

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/inyourlark/config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            FileHandle.standardError.write(
                "inyourlark: config.json is invalid (\(error)); using defaults\n".data(using: .utf8)!)
            return Config()
        }
    }

    func save() throws {
        let dir = Config.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Config.fileURL, options: .atomic)
    }

    /// True when `date` falls inside the configured quiet window (handles windows crossing midnight).
    func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard let q = quietHours,
              let start = Config.minutes(q.start),
              let end = Config.minutes(q.end) else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return start <= end ? (now >= start && now < end) : (now >= start || now < end)
    }

    private static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}
