import AppKit

// Ancla: one menu bar app that owns the cadence and conducts the anchor cycle.
//   ancla              run the menu bar app (what the LaunchAgent does)
//   ancla fire         show a rep now in the running app
//   ancla sit          start a 5-minute sit in the running app
//   ancla preview [mode] [mission]   show one overlay without touching state
//   ancla status       print schedule + counters

let usage = """
usage: ancla <command>
  (no argument)                 run the menu bar app
  fire                          show a rep now
  sit                           start a 5-minute sit now
  sits on|off                   morning + night sits
  rhythm short|normal|long      time between reps
  log training|live <text>      add a practice log entry
  preview [breath|stand|change|test|mission|sit] [text]
                                show one overlay without touching state
                                (ANCLA_SIT_SECONDS=20 shortens a sit preview)
  status                        print schedule + counters
"""

func post(_ name: Notification.Name, _ object: String? = nil) {
    guard appIsRunning() else {
        print("ancla is not running. start it with: launchctl kickstart gui/\(getuid())/com.pepe.ancla")
        exit(1)
    }
    DistributedNotificationCenter.default().postNotificationName(
        name, object: object, userInfo: nil, deliverImmediately: true)
}

/// flock-based singleton: the kernel drops the lock when the process dies,
/// so a crash can never leave a stale lock behind.
func acquireLock() -> Bool {
    try? FileManager.default.createDirectory(atPath: Paths.stateDir, withIntermediateDirectories: true)
    let fd = open(Paths.lock, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        close(fd)
        return false
    }
    return true // fd intentionally stays open for the process lifetime
}

func appIsRunning() -> Bool {
    let fd = open(Paths.lock, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
        flock(fd, LOCK_UN)
        return false
    }
    return true
}

let args = Array(CommandLine.arguments.dropFirst())
let app = NSApplication.shared

switch args.first {
case "fire":
    post(Scheduler.fireNotification)
    print("rep sent")
    exit(0)

case "sit":
    post(Scheduler.sitNotification)
    print("sit sent")
    exit(0)

case "sits":
    guard args.count == 2, args[1] == "on" || args[1] == "off" else { print(usage); exit(2) }
    post(Scheduler.sitsNotification, args[1])
    print("sits \(args[1])")
    exit(0)

case "rhythm":
    guard args.count == 2, Rhythm(rawValue: args[1]) != nil else { print(usage); exit(2) }
    post(Scheduler.rhythmNotification, args[1])
    print("rhythm \(args[1])")
    exit(0)

case "log":
    let kinds = ["training", "live"]
    guard args.count >= 3, kinds.contains(args[1]) else { print(usage); exit(2) }
    let text = args.dropFirst(2).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { print(usage); exit(2) }
    try? FileManager.default.createDirectory(atPath: Paths.stateDir, withIntermediateDirectories: true)
    Log.practice(kind: args[1], text: text)
    print("logged \(args[1]): \(text)")
    print(StatusText.training())
    exit(0)

case "status":
    guard let s = Store.readOnly() else {
        print("no state yet (\(Paths.state))")
        exit(1)
    }
    let running = appIsRunning()
    print("app:      \(running ? "running" : "NOT running")")
    print("schedule: \(StatusText.schedule(s, showing: s.overlayInFlight != nil, away: Presence.away))")
    print("reps:     \(StatusText.summary(s))")
    print("rhythm:   \(s.rhythm.label)")
    print("sits:     \(s.sitsEnabled ? StatusText.sits(s) : "off")")
    print("practice: \(StatusText.training())")
    print("away:     \(Presence.away ? "yes" : "no") (idle \(Int(Presence.idleSeconds))s)")
    if let f = s.lastFailure { print("FAILURE:  \(f)") }
    exit(running ? 0 : 1)

case "preview":
    let mode = args.count > 1 ? args[1] : "breath"
    let mission = args.count > 2 ? args[2] : "test mission"
    app.setActivationPolicy(.accessory)
    var content = OverlayContent(mode: mode, mission: mission, meta: "⚓ ancla · preview")
    if mode == "sit" { content.sitKind = "preview" }
    var preview: Overlay!
    preview = Overlay(content: content) { outcome in
        let extra = mode == "sit" ? "; \(preview.sitReturns) returns; word: \(preview.sitWord.isEmpty ? "-" : preview.sitWord)" : ""
        print("preview \(mode): \(outcome.logValue)\(extra)")
        exit(0)
    }
    DispatchQueue.main.async {
        preview.show()
        if !preview.isOnScreen {
            print("preview: overlay did not reach the screen")
            exit(1)
        }
    }
    app.run()

case nil, "run":
    guard acquireLock() else {
        // Exit 0 so launchd's KeepAlive(SuccessfulExit=false) does not respawn a duplicate.
        print("ancla ya está corriendo")
        exit(0)
    }
    app.setActivationPolicy(.accessory)
    let store = Store()
    let scheduler = Scheduler(store: store)
    let menuBar = MenuBar(scheduler: scheduler)
    scheduler.onChange = { [weak menuBar] in menuBar?.refreshTitle() }
    scheduler.start()
    withExtendedLifetime((scheduler, menuBar)) { app.run() }

default:
    print(usage)
    exit(args.first == "help" || args.first == "-h" || args.first == "--help" ? 0 : 2)
}
