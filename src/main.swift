import AppKit

// Ancla: one menu bar app that owns the cadence and conducts the anchor cycle.
//   ancla              run the menu bar app (what the LaunchAgent does)
//   ancla fire         show a rep now in the running app
//   ancla preview [mode] [mission]   show one overlay without touching state
//   ancla status       print schedule + counters

let usage = """
usage: ancla [fire | preview [breath|stand|change|test|mission] [text] | status]
  (no argument) run the menu bar app
"""

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
    guard appIsRunning() else {
        print("ancla no está corriendo. arráncalo con: launchctl kickstart gui/\(getuid())/com.pepe.ancla")
        exit(1)
    }
    DistributedNotificationCenter.default().postNotificationName(
        Scheduler.fireNotification, object: nil, userInfo: nil, deliverImmediately: true)
    print("rep enviado")
    exit(0)

case "status":
    guard let s = Store.readOnly() else {
        print("sin estado todavía (\(Paths.state))")
        exit(1)
    }
    let running = appIsRunning()
    print("app:     \(running ? "corriendo" : "NO está corriendo")")
    print("agenda:  \(StatusText.schedule(s, showing: s.overlayInFlight != nil, away: Presence.away))")
    print("reps:    \(StatusText.summary(s))")
    print("ritmo:   \(s.rhythm.label)")
    print("ausente: \(Presence.away ? "sí" : "no") (idle \(Int(Presence.idleSeconds))s)")
    if let f = s.lastFailure { print("FALLO:   \(f)") }
    exit(running ? 0 : 1)

case "preview":
    let mode = args.count > 1 ? args[1] : "breath"
    let mission = args.count > 2 ? args[2] : "misión de prueba"
    app.setActivationPolicy(.accessory)
    let preview = Overlay(content: OverlayContent(mode: mode, mission: mission, meta: "⚓ ancla · preview")) { outcome in
        print("preview \(mode): \(outcome.logValue)")
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
