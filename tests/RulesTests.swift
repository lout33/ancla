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
        func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
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

        if failures == 0 {
            print("all rule checks passed")
            exit(0)
        }
        print("\(failures) check(s) failed")
        exit(1)
    }
}
