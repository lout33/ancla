import Foundation

// Rule checks for the scheduling logic — run with ./test.sh
// (no Xcode required, same swiftc the build uses).

@main
struct RulesTests {
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures += 1; print("FAIL:", message) }
        }

        let cal = Calendar.current
        func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
            cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: min))!
        }
        let day0 = at(2026, 9, 27, 12)

        // Mode rotation over 12 reps with no mission set:
        // every 4th is a body rep (stand/change alternating), every 6th unguided.
        var s = AnclaState()
        var modes: [String] = []
        for i in 0..<12 {
            let m = Scheduler.nextMode(s, mission: "", now: day0)
            modes.append(m)
            Scheduler.applyRep(&s, mode: m, now: day0.addingTimeInterval(Double(i) * 60))
        }
        check(modes == ["breath", "breath", "breath", "stand", "breath", "test",
                        "breath", "change", "breath", "breath", "breath", "test"],
              "rotation was \(modes)")

        // Mission rides the first rep of the day, once.
        var m = AnclaState()
        check(Scheduler.nextMode(m, mission: "x", now: day0) == "mission", "mission on first rep")
        Scheduler.applyRep(&m, mode: "mission", now: day0)
        check(Scheduler.nextMode(m, mission: "x", now: day0) != "mission", "mission shown once per day")
        check(Scheduler.nextMode(m, mission: "x", now: day0.addingTimeInterval(86_400)) == "mission",
              "mission again the next day")

        // Streaks: consecutive days grow, gaps reset, and the streak survives
        // until the end of the day after its last rep.
        var st = AnclaState()
        Scheduler.applyRep(&st, mode: "breath", now: day0)
        Scheduler.applyRep(&st, mode: "breath", now: day0.addingTimeInterval(3600))
        check(st.streakDays == 1 && st.repsToday == 2, "same day: no double streak")
        Scheduler.applyRep(&st, mode: "breath", now: day0.addingTimeInterval(86_400))
        check(st.streakDays == 2 && st.repsToday == 1, "next day grows the streak")
        check(st.currentStreak(now: day0.addingTimeInterval(2 * 86_400)) == 2, "streak alive the day after")
        check(st.currentStreak(now: day0.addingTimeInterval(3 * 86_400)) == 0, "streak dead after a gap")
        Scheduler.applyRep(&st, mode: "breath", now: day0.addingTimeInterval(4 * 86_400))
        check(st.streakDays == 1, "streak restarts after a gap")

        // "Until tomorrow" = the next 08:00 at least 4 hours away.
        check(cal.component(.day, from: Day.tomorrowMorning(from: at(2026, 9, 28, 1))) == 28,
              "at 1 AM, tomorrow morning is this morning's 8:00")
        check(cal.component(.day, from: Day.tomorrowMorning(from: at(2026, 9, 27, 13))) == 28,
              "at 13:00, tomorrow morning is the next day's 8:00")

        // Tolerant decoding: unknown or missing keys must never wipe saved state.
        let partial = try! JSONDecoder().decode(AnclaState.self, from: #"""
        {"launchCount": 7, "someFutureKey": 1}
        """#.data(using: .utf8)!)
        check(partial.launchCount == 7 && partial.rhythm == .normal, "tolerant decode")

        // Rhythm presets always produce intervals inside their advertised range.
        for rhythm in Rhythm.allCases {
            for _ in 0..<200 {
                let minutes = rhythm.randomInterval() / 60
                check(rhythm.range.contains(minutes), "rhythm \(rhythm.rawValue) out of range")
            }
        }

        // Sit day rolls over at 03:00, so the 00:30 night sit belongs to the day ending.
        check(Sit.dayKey(at(2026, 10, 2, 0, 45)) == "2026-10-01", "00:45 is still yesterday's sit day")
        check(Sit.dayKey(at(2026, 10, 2, 3)) == "2026-10-02", "03:00 starts a new sit day")

        // Night window 00:30–02:00, once per sit day, missed at 02:00.
        var ns = AnclaState()
        check(!Sit.nightDue(ns, now: at(2026, 10, 2, 0, 29)), "night sit not before 00:30")
        check(Sit.nightDue(ns, now: at(2026, 10, 2, 0, 30)), "night sit due at 00:30")
        check(Sit.nightDue(ns, now: at(2026, 10, 2, 1, 59)), "night sit still due at 01:59")
        check(!Sit.nightDue(ns, now: at(2026, 10, 2, 2)), "night window closed at 02:00")
        check(Sit.nightMissed(ns, now: at(2026, 10, 2, 2, 5)), "night sit missed at 02:00")
        ns.sitDoneNight = "2026-10-01"
        check(!Sit.nightDue(ns, now: at(2026, 10, 2, 1)), "night sit done for the day")
        check(!Sit.nightMissed(ns, now: at(2026, 10, 2, 2, 5)), "done night sit is not missed")
        check(Sit.nightDue(ns, now: at(2026, 10, 3, 0, 40)), "night sit due again the next night")

        // Morning window 05:00–14:00; missed after 14:00 or past midnight.
        var ms = AnclaState()
        check(!Sit.morningWindowOpen(now: at(2026, 10, 2, 4, 59)), "no morning sit before 05:00")
        check(Sit.morningWindowOpen(now: at(2026, 10, 2, 7, 31)), "morning window open at 07:31")
        check(!Sit.morningWindowOpen(now: at(2026, 10, 2, 14)), "morning window closed at 14:00")
        check(!Sit.morningMissed(ms, now: at(2026, 10, 2, 11)), "not missed inside the window")
        check(Sit.morningMissed(ms, now: at(2026, 10, 2, 14, 1)), "missed after 14:00")
        check(Sit.morningMissed(ms, now: at(2026, 10, 3, 1)), "missed past midnight for the day ending")
        ms.sitDoneMorning = "2026-10-02"
        check(!Sit.morningMissed(ms, now: at(2026, 10, 2, 15)), "done morning sit is not missed")
        check(!Sit.morningMissed(ms, now: at(2026, 10, 3, 1)), "done morning sit is not missed past midnight")
        var late = AnclaState()
        Sit.closePassedSlots(&late, now: at(2026, 10, 1, 23, 15))
        check(late.sitDoneMorning == "2026-10-01" && late.sitDoneNight == nil,
              "switching on at 23:15 closes the morning, keeps tonight's sit")
        var early = AnclaState()
        Sit.closePassedSlots(&early, now: at(2026, 10, 2, 8))
        check(early.sitDoneMorning == nil, "switching on at 08:00 keeps the morning sit")
        check(Sit.pendingWindowOpen("manual", now: at(2026, 10, 2, 16)), "manual sits have no window")

        // If-thens rotate across reps; no file means random intentions.
        let lines = ["a", "b"]
        check(Scheduler.intention(ifThens: [], rep: 3) == nil, "no if-thens → nil")
        check((1...4).map { Scheduler.intention(ifThens: lines, rep: $0)! } == ["a", "b", "a", "b"],
              "if-thens rotate")
        check(Scheduler.intention(ifThens: lines, rep: 0) == "b", "rep 0 does not crash")

        // Practice CSV: the text field survives commas and quotes.
        check(Practice.csvField(#"run, 30 "min""#) == #""run, 30 ""min""""#, "csv quoting")

        // Weekly count starts Monday 00:00 and filters by kind.
        let tmp = NSTemporaryDirectory() + "ancla-practice-test-\(getpid()).csv"
        try! """
        date,kind,text
        2026-09-27 10:00:00,training,"sunday, last week"
        2026-09-28 00:10:00,training,"monday"
        2026-09-30 18:00:00,training,"run, 30 min"
        2026-09-30 19:00:00,live,"one sincere line"
        2026-10-01 08:00:00,sit,"morning completed"
        2026-10-09 08:00:00,training,"future"
        """.write(toFile: tmp, atomically: true, encoding: .utf8)
        let thursday = at(2026, 10, 1, 12)
        check(Practice.weekCount(kind: "training", path: tmp, now: thursday) == 2, "training this week")
        check(Practice.weekCount(kind: "live", path: tmp, now: thursday) == 1, "live reps this week")
        check(Practice.weekCount(kind: "sit", containing: "completed", path: tmp, now: thursday) == 1,
              "completed sits this week")
        check(Practice.weekCount(kind: "sit", containing: "missed", path: tmp, now: thursday) == 0,
              "text filter")
        check(Practice.weekCount(kind: "training", path: tmp + ".missing", now: thursday) == 0, "missing file → 0")
        try? FileManager.default.removeItem(atPath: tmp)

        let ifPath = NSTemporaryDirectory() + "ancla-ifthens-test-\(getpid()).txt"
        try! "  first → do x  \n\n second\n".write(toFile: ifPath, atomically: true, encoding: .utf8)
        check(Practice.ifThens(path: ifPath) == ["first → do x", "second"], "if-thens file parsing")
        try? FileManager.default.removeItem(atPath: ifPath)

        if failures == 0 {
            print("all rule checks passed")
            exit(0)
        }
        print("\(failures) check(s) failed")
        exit(1)
    }
}
