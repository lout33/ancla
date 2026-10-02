import Foundation

enum Paths {
    static let stateDir = NSHomeDirectory() + "/.local/state"
    static let state = stateDir + "/ancla.json"
    static let repLog = stateDir + "/ancla-log.csv"
    static let events = stateDir + "/ancla-events.log"
    static let mission = stateDir + "/ancla-mission.txt"
    static let lock = stateDir + "/ancla.lock"
    static let practice = stateDir + "/ancla-practice.csv"
    static let ifThens = stateDir + "/ancla-ifthens.txt"
}

enum Rhythm: String, Codable, CaseIterable {
    case short, normal, long

    /// Minutes between reps. Variable on purpose: fixed intervals go invisible.
    var range: ClosedRange<Double> {
        switch self {
        case .short: return 15...25
        case .normal: return 20...40
        case .long: return 40...60
        }
    }

    var label: String {
        switch self {
        case .short: return "short (15–25 min)"
        case .normal: return "normal (20–40 min)"
        case .long: return "long (40–60 min)"
        }
    }

    func randomInterval() -> TimeInterval { Double.random(in: range) * 60 }
}

struct AnclaState: Codable, Equatable {
    var nextDue = Date()
    /// nil = running. Date.distantFuture = paused until manually resumed.
    var pausedUntil: Date?
    var lastRep: Date?
    var launchCount = 0
    var lastBody = "change"
    var streakDays = 0
    var streakDate: String?
    var repsDate: String?
    var repsToday = 0
    var missionShownDate: String?
    var rhythm = Rhythm.normal
    /// Set before an overlay is shown and cleared when it finishes. If it is
    /// still set at startup, the previous process died mid-rep.
    var overlayInFlight: Date?
    var lastFailure: String?
    /// Sits are off until switched on in the menu.
    var sitsEnabled = false
    /// Sit-day keys (see Sit.dayKey) of the last morning and night sit shown or missed.
    var sitDoneMorning: String?
    var sitDoneNight: String?
    /// "morning" | "night" while a sit is due and waiting for you.
    var sitPending: String?
    var sitPendingSince: Date?

    init() {}

    // Tolerant decoding: a missing or renamed key must never wipe the state.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AnclaState()
        nextDue = (try? c.decodeIfPresent(Date.self, forKey: .nextDue)) ?? d.nextDue
        pausedUntil = try? c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        lastRep = try? c.decodeIfPresent(Date.self, forKey: .lastRep)
        launchCount = (try? c.decodeIfPresent(Int.self, forKey: .launchCount)) ?? d.launchCount
        lastBody = (try? c.decodeIfPresent(String.self, forKey: .lastBody)) ?? d.lastBody
        streakDays = (try? c.decodeIfPresent(Int.self, forKey: .streakDays)) ?? d.streakDays
        streakDate = try? c.decodeIfPresent(String.self, forKey: .streakDate)
        repsDate = try? c.decodeIfPresent(String.self, forKey: .repsDate)
        repsToday = (try? c.decodeIfPresent(Int.self, forKey: .repsToday)) ?? d.repsToday
        missionShownDate = try? c.decodeIfPresent(String.self, forKey: .missionShownDate)
        rhythm = (try? c.decodeIfPresent(Rhythm.self, forKey: .rhythm)) ?? d.rhythm
        overlayInFlight = try? c.decodeIfPresent(Date.self, forKey: .overlayInFlight)
        lastFailure = try? c.decodeIfPresent(String.self, forKey: .lastFailure)
        sitsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .sitsEnabled)) ?? d.sitsEnabled
        sitDoneMorning = try? c.decodeIfPresent(String.self, forKey: .sitDoneMorning)
        sitDoneNight = try? c.decodeIfPresent(String.self, forKey: .sitDoneNight)
        sitPending = try? c.decodeIfPresent(String.self, forKey: .sitPending)
        sitPendingSince = try? c.decodeIfPresent(Date.self, forKey: .sitPendingSince)
    }

    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    func repsShownToday(now: Date = Date()) -> Int {
        repsDate == Day.key(now) ? repsToday : 0
    }

    /// A streak survives until the end of the day after its last rep.
    func currentStreak(now: Date = Date()) -> Int {
        guard let d = streakDate else { return 0 }
        return (d == Day.key(now) || d == Day.key(Day.yesterday(now))) ? streakDays : 0
    }
}

enum Day {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func key(_ date: Date) -> String { formatter.string(from: date) }
    static func time(_ date: Date) -> String { clock.string(from: date) }
    static func stampString(_ date: Date) -> String { stamp.string(from: date) }
    static func parseStamp(_ text: String) -> Date? { stamp.date(from: text) }
    static func yesterday(_ date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date
    }

    /// Next 08:00 that is at least 4 hours away ("until tomorrow" when
    /// pausing at 1 AM means this morning, not the morning after).
    static func tomorrowMorning(from now: Date = Date()) -> Date {
        let cal = Calendar.current
        var target = cal.nextDate(after: now, matching: DateComponents(hour: 8, minute: 0),
                                  matchingPolicy: .nextTime) ?? now.addingTimeInterval(8 * 3600)
        if target.timeIntervalSince(now) < 4 * 3600 {
            target = cal.date(byAdding: .day, value: 1, to: target) ?? target
        }
        return target
    }
}

final class Store {
    private(set) var state: AnclaState

    init() {
        try? FileManager.default.createDirectory(atPath: Paths.stateDir, withIntermediateDirectories: true)
        if let data = FileManager.default.contents(atPath: Paths.state),
           let s = try? Store.decoder.decode(AnclaState.self, from: data) {
            state = s
        } else {
            state = Store.migrateFromV1()
            save()
            Log.event("state created at \(Paths.state)")
        }
    }

    func update(_ change: (inout AnclaState) -> Void) {
        change(&state)
        save()
    }

    private func save() {
        guard let data = try? Store.encoder.encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: Paths.state), options: .atomic)
    }

    static func readOnly() -> AnclaState? {
        guard let data = FileManager.default.contents(atPath: Paths.state) else { return nil }
        return try? decoder.decode(AnclaState.self, from: data)
    }

    var mission: String {
        guard let d = FileManager.default.contents(atPath: Paths.mission),
              let s = String(data: d, encoding: .utf8) else { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setMission(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try? (t.isEmpty ? "" : t + "\n").write(toFile: Paths.mission, atomically: true, encoding: .utf8)
        // A freshly written mission should ride the next rep, even if one was shown today.
        update { $0.missionShownDate = nil }
    }

    /// v1 counters (streak, reps today, last launch) counted crashed and
    /// skipped launches as reps, so they are not carried over. Only the mode
    /// rotation continues.
    private static func migrateFromV1() -> AnclaState {
        func read(_ name: String) -> String? {
            guard let d = FileManager.default.contents(atPath: Paths.stateDir + "/" + name) else { return nil }
            return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var s = AnclaState()
        if let n = read("movement-count.state").flatMap(Int.init) { s.launchCount = n }
        s.lastBody = read("movement-reminder.state") == "stand" ? "stand" : "change"
        s.nextDue = Date().addingTimeInterval(2 * 60)
        return s
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

enum Log {
    private static let maxEventBytes = 512 * 1024

    /// Human-readable trail of everything the scheduler decides, including
    /// skips and failures, so silent breakage cannot hide again.
    static func event(_ message: String) {
        trimIfNeeded()
        append("\(Day.stampString(Date())) \(message)\n", to: Paths.events)
    }

    static func rep(at date: Date, mode: String, outcome: String) {
        if !FileManager.default.fileExists(atPath: Paths.repLog) {
            append("fecha,modo,resultado\n", to: Paths.repLog)
        }
        append("\(Day.stampString(date)),\(mode),\(outcome)\n", to: Paths.repLog)
    }

    /// One line per practice entry (sit, training, live rep). The text field is
    /// quoted so a comma or quote in what you typed cannot break the CSV.
    static func practice(kind: String, text: String, at date: Date = Date()) {
        if !FileManager.default.fileExists(atPath: Paths.practice) {
            append("date,kind,text\n", to: Paths.practice)
        }
        append("\(Day.stampString(date)),\(kind),\(Practice.csvField(text))\n", to: Paths.practice)
    }

    private static func append(_ line: String, to path: String) {
        let data = Data(line.utf8)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    private static func trimIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.events),
              let size = attrs[.size] as? Int, size > maxEventBytes,
              let data = FileManager.default.contents(atPath: Paths.events) else { return }
        try? data.suffix(maxEventBytes / 2).write(to: URL(fileURLWithPath: Paths.events), options: .atomic)
    }
}

/// The practice log (sits, training, live reps) and the if-then lines that
/// ride each rep. Personal practice data stays in ~/.local/state, never in
/// the repo.
enum Practice {
    static func csvField(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// One if-then per line in ancla-ifthens.txt; reps rotate through them.
    static func ifThens(path: String = Paths.ifThens) -> [String] {
        guard let d = FileManager.default.contents(atPath: path),
              let s = String(data: d, encoding: .utf8) else { return [] }
        return s.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Entries of one kind since Monday 00:00, for the menu and `ancla status`.
    static func weekCount(kind: String, containing: String? = nil,
                          path: String = Paths.practice, now: Date = Date()) -> Int {
        guard let d = FileManager.default.contents(atPath: path),
              let text = String(data: d, encoding: .utf8) else { return 0 }
        var cal = Calendar.current
        cal.firstWeekday = 2
        guard let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start else { return 0 }
        var count = 0
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: ",", maxSplits: 2)
            guard cols.count == 3, cols[1] == Substring(kind),
                  let date = Day.parseStamp(String(cols[0])),
                  date >= weekStart, date <= now,
                  containing.map({ cols[2].contains($0) }) ?? true else { continue }
            count += 1
        }
        return count
    }
}
