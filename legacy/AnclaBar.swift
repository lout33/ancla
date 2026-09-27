import AppKit

// AnclaBar — menu bar indicator for the Ancla metronome.
// ⚓ + minutes since last rep. Menu: fire now, pause/resume, open log, quit.
// Compile: swiftc AnclaBar.swift -o AnclaBar

let agentLabel = "com.pepe.movement"
let agentPlist = NSHomeDirectory() + "/Library/LaunchAgents/com.pepe.movement.plist"
let stateDir = NSHomeDirectory() + "/.local/state"

func read(_ path: String) -> String? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

@discardableResult
func shell(_ command: String) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", command]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

func agentLoaded() -> Bool {
    shell("launchctl print gui/\(getuid())/\(agentLabel) >/dev/null 2>&1") == 0
}

func lastRepMinutes() -> Int? {
    guard let s = read(stateDir + "/ancla-lastlaunch"), let epoch = Double(s) else { return nil }
    return Int((Date().timeIntervalSince1970 - epoch) / 60)
}

func repsToday() -> Int {
    guard let s = read(stateDir + "/ancla-count") else { return 0 }
    let p = s.split(separator: " ")
    let today = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
    return (p.count == 2 && p[0] == today) ? (Int(p[1]) ?? 0) : 0
}

func streakDays() -> Int {
    guard let s = read(stateDir + "/ancla-streak") else { return 0 }
    let p = s.split(separator: " ")
    return (p.count == 2) ? (Int(p[0]) ?? 0) : 0
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
let infoItem = NSMenuItem(title: "—", action: nil, keyEquivalent: "")
let pauseItem = NSMenuItem(title: "Pausar metrónomo", action: #selector(MenuTarget.togglePause), keyEquivalent: "")

final class StatusLine {
    static var paused = false
}

func refresh() {
    let loaded = agentLoaded()
    let paused = StatusLine.paused
    let m = lastRepMinutes()

    if paused || !loaded {
        statusItem.button?.title = "⚓ ✕"
    } else if let m = m, m < 120 {
        statusItem.button?.title = "⚓ \(m)m"
    } else {
        statusItem.button?.title = "⚓ ?"
    }

    infoItem.title = paused
        ? "PAUSADO — el metrónomo no dispara"
        : "último rep: \(m.map { "\($0) min" } ?? "—") ago · reps hoy: \(repsToday()) · racha \(streakDays())d"
    pauseItem.title = paused ? "Reanudar metrónomo" : "Pausar metrónomo"
    _ = loaded
}

final class MenuTarget: NSObject {
    @objc func fireNow() {
        if StatusLine.paused { resume() }
        // force flag bypasses the variable-cadence gate in the metronome script
        _ = shell("touch ~/.local/state/ancla-force && launchctl kickstart gui/\(getuid())/\(agentLabel)")
        refresh()
    }
    @objc func togglePause() {
        if StatusLine.paused { resume() } else { pause() }
        refresh()
    }
    func pause() {
        _ = shell("launchctl bootout gui/\(getuid())/\(agentLabel)")
        StatusLine.paused = true
    }
    func resume() {
        // bootstrap is the modern API; load is the fallback (macOS 26 load is broken)
        _ = shell("launchctl bootstrap gui/\(getuid()) \(agentPlist) 2>/dev/null || launchctl load \(agentPlist)")
        StatusLine.paused = false
    }
    @objc func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: stateDir + "/ancla-log.csv"))
    }
    @objc func openMission() {
        let path = stateDir + "/ancla-mission.txt"
        if !FileManager.default.fileExists(atPath: path) {
            try? "escribe aquí la misión de hoy".write(toFile: path, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
    @objc func quit() { NSApp.terminate(nil) }
}

let target = MenuTarget()
pauseItem.target = target

let menu = NSMenu()
menu.addItem(infoItem)
menu.addItem(.separator())
menu.addItem(MenuItem("Fuego ahora", target, #selector(MenuTarget.fireNow)))
menu.addItem(pauseItem)
menu.addItem(.separator())
menu.addItem(MenuItem("Editar misión de hoy", target, #selector(MenuTarget.openMission)))
menu.addItem(MenuItem("Ver log de reps", target, #selector(MenuTarget.openLog)))
menu.addItem(.separator())
menu.addItem(MenuItem("Salir", target, #selector(MenuTarget.quit)))
statusItem.menu = menu

func MenuItem(_ title: String, _ target: NSObject, _ action: Selector) -> NSMenuItem {
    let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
    mi.target = target
    return mi
}

refresh()
let clock = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in refresh() }
RunLoop.main.add(clock, forMode: .common)
app.run()
