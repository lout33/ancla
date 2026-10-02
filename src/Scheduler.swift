import AppKit

enum Presence {
    static let awayAfter: TimeInterval = 120

    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                eventType: CGEventType(rawValue: ~0)!)
    }

    static var screenLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    static var away: Bool { idleSeconds > awayAfter || screenLocked }
}

enum StatusText {
    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let m = Int(now.timeIntervalSince(date) / 60)
        if m < 1 { return "just now" }
        if m < 60 { return "\(m) min ago" }
        if m < 24 * 60 { return "\(m / 60) h ago" }
        return "\(m / (24 * 60)) d ago"
    }

    static func schedule(_ s: AnclaState, showing: Bool, away: Bool, now: Date = Date()) -> String {
        if showing { return "rep in progress" }
        if let p = s.pausedUntil, p > now {
            if p == .distantFuture { return "paused — until you resume" }
            let sameDay = Day.key(p) == Day.key(now)
            return "paused until \(Day.time(p))\(sameDay ? "" : " (tomorrow)")"
        }
        if now >= s.nextDue { return away ? "rep due — fires when you're back" : "rep due now" }
        let mins = Int((s.nextDue.timeIntervalSince(now) / 60).rounded(.up))
        return "next rep: in ~\(mins) min"
    }

    static func summary(_ s: AnclaState, now: Date = Date()) -> String {
        "last rep: \(ago(s.lastRep, now: now)) · today \(s.repsShownToday(now: now)) · streak \(s.currentStreak(now: now))d"
    }

    static func sits(_ s: AnclaState, now: Date = Date()) -> String {
        let day = Sit.dayKey(now)
        // "closed" covers sat, ended and missed; the practice log tells which.
        func slot(_ done: String?, _ kind: String) -> String {
            done == day ? "closed" : s.sitPending == kind ? "waiting" : "open"
        }
        return "morning \(slot(s.sitDoneMorning, "morning")) · night \(slot(s.sitDoneNight, "night")) (00:30) · completed this week \(Practice.weekCount(kind: "sit", containing: "completed", now: now))"
    }

    /// Floor from LIFE: 2 training sessions a week.
    static func training(now: Date = Date()) -> String {
        "training this week: \(Practice.weekCount(kind: "training", now: now)) / 2 · live reps \(Practice.weekCount(kind: "live", now: now))"
    }
}

/// Owns the cadence: decides when a rep is due, waits for you when you are
/// away, and shows the overlay in-process.
final class Scheduler {
    static let fireNotification = Notification.Name("com.pepe.ancla.fire")
    static let sitNotification = Notification.Name("com.pepe.ancla.sit")
    static let sitsNotification = Notification.Name("com.pepe.ancla.sits")
    static let rhythmNotification = Notification.Name("com.pepe.ancla.rhythm")
    private static let tickInterval: TimeInterval = 10
    /// Breathing room after login or wake before a due rep may fire.
    private static let settleDelay: TimeInterval = 60

    let store: Store
    var onChange: () -> Void = {}
    private(set) var overlay: Overlay?
    private var timer: Timer?
    private var announcedWaiting = false
    /// When the machine went idle/locked; the gap on return drives the
    /// morning sit. In memory only: a restart re-derives it from presence.
    private var awaySince: Date?
    private var lastAwayGap: TimeInterval?

    init(store: Store) { self.store = store }

    var showing: Bool { overlay != nil }

    func start() {
        let now = Date()
        if let t = store.state.overlayInFlight {
            // A crash-looping overlay must not refire every few seconds, so
            // the next attempt waits a full interval.
            let message = "the \(Day.time(t)) rep died before finishing"
            store.update {
                $0.overlayInFlight = nil
                $0.lastFailure = message
                $0.nextDue = now.addingTimeInterval($0.rhythm.randomInterval())
            }
            Log.event("FAILURE \(message) (process died mid-rep; see ~/Library/Logs/DiagnosticReports)")
        }
        store.update { $0.nextDue = max($0.nextDue, now.addingTimeInterval(Scheduler.settleDelay)) }
        Log.event("started; \(StatusText.schedule(store.state, showing: false, away: false))")

        let t = Timer(timeInterval: Scheduler.tickInterval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.didWake()
        }
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(
            forName: Scheduler.fireNotification, object: nil, queue: .main) { [weak self] _ in
            self?.fire(reason: "cli")
        }
        dc.addObserver(
            forName: Scheduler.sitNotification, object: nil, queue: .main) { [weak self] _ in
            self?.fireSit(kind: "manual")
        }
        dc.addObserver(
            forName: Scheduler.sitsNotification, object: nil, queue: .main) { [weak self] n in
            self?.setSitsEnabled((n.object as? String) == "on")
        }
        dc.addObserver(
            forName: Scheduler.rhythmNotification, object: nil, queue: .main) { [weak self] n in
            if let raw = n.object as? String, let r = Rhythm(rawValue: raw) { self?.setRhythm(r) }
        }

        // A launch inside the morning window (login, or a restart) offers the
        // morning sit; the pending delay doubles as the settle time.
        if store.state.sitsEnabled, store.state.sitPending == nil,
           Sit.morningWindowOpen(now: now), store.state.sitDoneMorning != Sit.dayKey(now) {
            store.update { $0.sitPending = "morning"; $0.sitPendingSince = now }
            Log.event("morning sit pending from launch")
        }
        tick()
    }

    private func didWake() {
        store.update { $0.nextDue = max($0.nextDue, Date().addingTimeInterval(Scheduler.settleDelay)) }
        Log.event("woke from sleep; \(StatusText.schedule(store.state, showing: showing, away: false))")
        onChange()
    }

    private func tick() {
        defer { onChange() }
        let now = Date()

        if Presence.away {
            if awaySince == nil { awaySince = now }
            lastAwayGap = nil
        } else {
            if let since = awaySince { lastAwayGap = now.timeIntervalSince(since) }
            awaySince = nil
        }

        guard overlay == nil else { return }

        if let p = store.state.pausedUntil {
            guard p <= now else { return }
            resume(reason: "pause expired")
            return
        }
        tickSits(now: now)
        guard overlay == nil, now >= store.state.nextDue else { return }

        if Presence.away {
            if !announcedWaiting {
                announcedWaiting = true
                Log.event("rep due; away (idle \(Int(Presence.idleSeconds))s, locked \(Presence.screenLocked)) — waiting")
            }
            return
        }
        fire(reason: "scheduled")
    }

    // MARK: - Actions

    func fire(reason: String) {
        guard overlay == nil else { return }
        announcedWaiting = false
        let now = Date()
        let mission = store.mission
        let mode = Scheduler.nextMode(store.state, mission: mission, now: now)

        var projected = store.state
        Scheduler.applyRep(&projected, mode: mode, now: now)
        let streak = projected.streakDays > 1 ? " · racha \(projected.streakDays)d" : ""
        var content = OverlayContent(mode: mode, mission: mission,
                                     meta: "⚓ ancla · rep \(projected.repsToday) hoy\(streak)")
        if let practice = Scheduler.intention(ifThens: Practice.ifThens(), rep: projected.launchCount) {
            content.intention = practice
            content.intentionTitle = "practice"
        }

        store.update { $0.overlayInFlight = now }
        let ov = Overlay(content: content) { [weak self] outcome in
            self?.overlayFinished(mode: mode, shownAt: now, outcome: outcome)
        }
        overlay = ov
        ov.show()

        guard ov.isOnScreen else {
            overlay = nil
            let message = "the overlay did not appear at \(Day.time(now))"
            store.update {
                $0.overlayInFlight = nil
                $0.lastFailure = message
                $0.nextDue = now.addingTimeInterval(5 * 60)
            }
            Log.event("FAILURE \(message); retry in 5 min")
            onChange()
            return
        }

        store.update { Scheduler.applyRep(&$0, mode: mode, now: now) }
        let media = ov.pausedMedia.map { "; paused \($0.app): \($0.title)" } ?? ""
        Log.event("rep shown: \(mode) (\(reason)); intention: \(content.intention)\(media)")
        onChange()
    }

    private func overlayFinished(mode: String, shownAt: Date, outcome: OverlayOutcome) {
        let ov = overlay
        overlay = nil
        if mode == "sit" {
            let kind = ov.map { $0.content.sitKind.isEmpty ? "sit" : $0.content.sitKind } ?? "sit"
            let word = ov?.sitWord ?? ""
            let text = "\(kind) \(outcome.logValue); \(ov?.sitReturns ?? 0) returns; word: \(word.isEmpty ? "-" : word)"
            Log.practice(kind: "sit", text: text, at: shownAt)
            Log.event("sit \(text)")
        } else {
            Log.rep(at: shownAt, mode: mode, outcome: outcome.logValue)
        }
        // A sit also pushes the next rep a full interval out, so one never
        // lands right after the other.
        store.update {
            $0.overlayInFlight = nil
            $0.nextDue = Date().addingTimeInterval($0.rhythm.randomInterval())
        }
        Log.event("\(mode == "sit" ? "sit" : "rep \(mode)") \(outcome.logValue); \(StatusText.schedule(store.state, showing: false, away: false))")
        onChange()
    }

    // MARK: - Sits

    /// Morning sit: the first return after a night away. Night sit: 00:30,
    /// before the laptop closes. Each fires once per sit day, waits while you
    /// are away, and is logged as missed rather than fired at a wrong moment.
    private func tickSits(now: Date) {
        let s = store.state
        guard s.sitsEnabled, !s.isPaused else { return }

        if let pending = s.sitPending {
            let since = s.sitPendingSince ?? now
            guard Sit.pendingWindowOpen(pending, now: now) else {
                missSit(kind: pending, day: Sit.dayKey(since), now: now)
                return
            }
            if !Presence.away, now.timeIntervalSince(since) >= Sit.pendingSettle {
                fireSit(kind: pending, now: now)
            }
            return
        }

        if Sit.nightDue(s, now: now) {
            if Presence.away {
                store.update { $0.sitPending = "night"; $0.sitPendingSince = now }
                Log.event("night sit due; away — waiting until 02:00")
            } else {
                fireSit(kind: "night", now: now)
            }
            return
        }
        if Sit.nightMissed(s, now: now) {
            missSit(kind: "night", day: Sit.dayKey(now), now: now)
            return
        }

        let day = Sit.dayKey(now)
        if s.sitDoneMorning != day, Sit.morningWindowOpen(now: now),
           let gap = lastAwayGap, gap >= Sit.morningMinAway {
            lastAwayGap = nil
            store.update { $0.sitPending = "morning"; $0.sitPendingSince = now }
            Log.event("morning sit due; back after \(Int(gap / 3600)) h away — fires in \(Int(Sit.pendingSettle)) s")
            return
        }
        if Sit.morningMissed(s, now: now) {
            missSit(kind: "morning", day: day, now: now)
        }
    }

    /// A sit moves no rep counters (streak, reps today, rotation).
    func fireSit(kind: String, now: Date = Date()) {
        guard overlay == nil else { return }
        let title = kind == "night" ? "night sit" : kind == "morning" ? "morning sit" : "sit"
        var content = OverlayContent(mode: "sit", mission: "", meta: "⚓ ancla · \(title) · 5 min")
        content.sitKind = kind

        store.update {
            $0.overlayInFlight = now
            $0.sitPending = nil
            $0.sitPendingSince = nil
            let day = Sit.dayKey(now)
            switch kind {
            case "morning": $0.sitDoneMorning = day
            case "night": $0.sitDoneNight = day
            default:
                // A manual sit inside a window counts as that slot's sit.
                if Sit.morningWindowOpen(now: now) { $0.sitDoneMorning = day }
                else if Sit.nightWindowOpen(now: now) { $0.sitDoneNight = day }
            }
        }
        let ov = Overlay(content: content) { [weak self] outcome in
            self?.overlayFinished(mode: "sit", shownAt: now, outcome: outcome)
        }
        overlay = ov
        ov.show()

        guard ov.isOnScreen else {
            overlay = nil
            let message = "the sit overlay did not appear at \(Day.time(now))"
            store.update { $0.overlayInFlight = nil; $0.lastFailure = message }
            Log.event("FAILURE \(message)")
            onChange()
            return
        }
        Log.event("sit shown: \(kind)")
        onChange()
    }

    private func missSit(kind: String, day: String, now: Date) {
        store.update {
            $0.sitPending = nil
            $0.sitPendingSince = nil
            if kind == "morning" { $0.sitDoneMorning = day }
            if kind == "night" { $0.sitDoneNight = day }
        }
        Log.event("sit missed: \(kind)")
        Log.practice(kind: "sit", text: "\(kind) missed", at: now)
        onChange()
    }

    func sitNow() { fireSit(kind: "manual") }

    func setSitsEnabled(_ on: Bool) {
        store.update {
            $0.sitsEnabled = on
            if on { Sit.closePassedSlots(&$0, now: Date()) }
            else { $0.sitPending = nil; $0.sitPendingSince = nil }
        }
        Log.event("sits \(on ? "on" : "off")")
        onChange()
    }

    func pause(until date: Date) {
        store.update { $0.pausedUntil = date }
        Log.event("paused until \(date == .distantFuture ? "resumed" : Day.stampString(date))")
        onChange()
    }

    func resume(reason: String = "manual") {
        store.update {
            $0.pausedUntil = nil
            $0.nextDue = Date().addingTimeInterval($0.rhythm.randomInterval())
        }
        Log.event("resumed (\(reason)); \(StatusText.schedule(store.state, showing: false, away: false))")
        onChange()
    }

    func setRhythm(_ rhythm: Rhythm) {
        store.update {
            $0.rhythm = rhythm
            $0.nextDue = Date().addingTimeInterval(rhythm.randomInterval())
        }
        Log.event("rhythm → \(rhythm.rawValue)")
        onChange()
    }

    func clearFailure() {
        store.update { $0.lastFailure = nil }
        onChange()
    }

    // MARK: - Rules

    /// Mission rides the first rep of the day; every 6th rep is an unguided
    /// test (prompt fading); every 4th is a body rep, alternating stand/change.
    static func nextMode(_ s: AnclaState, mission: String, now: Date) -> String {
        let n = s.launchCount + 1
        if !mission.isEmpty && s.missionShownDate != Day.key(now) { return "mission" }
        if n % 6 == 0 { return "test" }
        if n % 4 == 0 { return s.lastBody == "stand" ? "change" : "stand" }
        return "breath"
    }

    static func applyRep(_ s: inout AnclaState, mode: String, now: Date) {
        let today = Day.key(now)
        s.launchCount += 1
        s.lastRep = now
        if mode == "stand" || mode == "change" { s.lastBody = mode }
        if mode == "mission" { s.missionShownDate = today }
        if s.repsDate == today { s.repsToday += 1 } else { s.repsDate = today; s.repsToday = 1 }
        if s.streakDate != today {
            s.streakDays = s.streakDate == Day.key(Day.yesterday(now)) ? s.streakDays + 1 : 1
            s.streakDate = today
        }
    }

    /// Rotates the active if-thens across reps; nil means "use a random intention".
    static func intention(ifThens: [String], rep: Int) -> String? {
        guard !ifThens.isEmpty else { return nil }
        return ifThens[((rep - 1) % ifThens.count + ifThens.count) % ifThens.count]
    }
}

/// Sit scheduling rules. The sit day rolls over at 03:00, so a night sit at
/// 00:30 belongs to the day that is ending.
enum Sit {
    static let rolloverHour = 3
    static let morningMinAway: TimeInterval = 5 * 3600
    /// A pending sit fires only after you have been back this long.
    static let pendingSettle: TimeInterval = 90

    static func dayKey(_ now: Date) -> String {
        Calendar.current.component(.hour, from: now) < rolloverHour
            ? Day.key(Day.yesterday(now)) : Day.key(now)
    }

    /// 00:30 until 02:00.
    static func nightWindowOpen(now: Date) -> Bool {
        let c = Calendar.current
        let h = c.component(.hour, from: now), m = c.component(.minute, from: now)
        return (h == 0 && m >= 30) || h == 1
    }

    static func nightDue(_ s: AnclaState, now: Date) -> Bool {
        nightWindowOpen(now: now) && s.sitDoneNight != dayKey(now)
    }

    static func nightMissed(_ s: AnclaState, now: Date) -> Bool {
        Calendar.current.component(.hour, from: now) == 2 && s.sitDoneNight != dayKey(now)
    }

    /// 05:00 until 14:00.
    static func morningWindowOpen(now: Date) -> Bool {
        let h = Calendar.current.component(.hour, from: now)
        return h >= 5 && h < 14
    }

    /// After 14:00, or after midnight for the day that is ending.
    static func morningMissed(_ s: AnclaState, now: Date) -> Bool {
        let h = Calendar.current.component(.hour, from: now)
        return (h >= 14 || h < rolloverHour) && s.sitDoneMorning != dayKey(now)
    }

    /// Switching sits on must not log misses for windows that closed while
    /// they were off.
    static func closePassedSlots(_ s: inout AnclaState, now: Date) {
        if morningMissed(s, now: now) { s.sitDoneMorning = dayKey(now) }
        if nightMissed(s, now: now) { s.sitDoneNight = dayKey(now) }
    }

    static func pendingWindowOpen(_ kind: String, now: Date) -> Bool {
        switch kind {
        case "night": return nightWindowOpen(now: now)
        case "morning": return morningWindowOpen(now: now)
        default: return true
        }
    }
}
