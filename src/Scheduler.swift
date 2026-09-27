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
}

/// Owns the cadence: decides when a rep is due, waits for you when you are
/// away, and shows the overlay in-process.
final class Scheduler {
    static let fireNotification = Notification.Name("com.pepe.ancla.fire")
    private static let tickInterval: TimeInterval = 10
    /// Breathing room after login or wake before a due rep may fire.
    private static let settleDelay: TimeInterval = 60

    let store: Store
    var onChange: () -> Void = {}
    private(set) var overlay: Overlay?
    private var timer: Timer?
    private var announcedWaiting = false

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
        DistributedNotificationCenter.default().addObserver(
            forName: Scheduler.fireNotification, object: nil, queue: .main) { [weak self] _ in
            self?.fire(reason: "cli")
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
        guard overlay == nil else { return }
        let now = Date()

        if let p = store.state.pausedUntil {
            guard p <= now else { return }
            resume(reason: "pause expired")
            return
        }
        guard now >= store.state.nextDue else { return }

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
        let content = OverlayContent(mode: mode, mission: mission,
                                     meta: "⚓ ancla · rep \(projected.repsToday) hoy\(streak)")

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
        overlay = nil
        Log.rep(at: shownAt, mode: mode, outcome: outcome.logValue)
        store.update {
            $0.overlayInFlight = nil
            $0.nextDue = Date().addingTimeInterval($0.rhythm.randomInterval())
        }
        Log.event("rep \(mode) \(outcome.logValue); \(StatusText.schedule(store.state, showing: false, away: false))")
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
}
