import AppKit

// Ancla — native full-screen interrupt that CONDUCTS the anchor cycle:
// presiona → exhala (guided deflate) → ensancha (expand) → gente, lento.
// Usage: open Ancla.app --args [stand|change]
// Compile: swiftc Ancla.swift -o ancla

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

let totalSeconds: Double = 15
let idleSkipSeconds: Double = 120

// Launch args (parsed early): mode, mission text, "force" flag
let args = CommandLine.arguments
let forceFlag = args.contains("force")

// Skip if nobody is at the desk — unless the launch was explicitly forced
let idle = CGEventSource.secondsSinceLastEventType(
    .combinedSessionState,
    eventType: CGEventType(rawValue: ~0)!
)
if idle > idleSkipSeconds && !forceFlag { exit(0) }

let fm = FileManager.default
let stateDir = NSHomeDirectory() + "/.local/state"

// Singleton guard: NSRunningApplication check + PID lockfile (race-proof)
let myBundle = Bundle.main.bundleIdentifier ?? "com.pepe.ancla"
if NSRunningApplication.runningApplications(withBundleIdentifier: myBundle).count > 1 { exit(0) }
let lockPath = stateDir + "/ancla.lock"
let myPID = ProcessInfo.processInfo.processIdentifier
if let d = fm.contents(atPath: lockPath),
   let s = String(data: d, encoding: .utf8),
   let pid = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)).map(pid_t.init),
   pid != myPID,
   kill(pid, 0) == 0 {
    exit(0)
}
try? "\(myPID)".write(toFile: lockPath, atomically: true, encoding: .utf8)

// Rep counter (resets daily)
try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
let countPath = stateDir + "/ancla-count"
var repLabel = ""
if let data = fm.contents(atPath: countPath),
   let text = String(data: data, encoding: .utf8) {
    let parts = text.split(separator: " ")
    let today = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
    if parts.count == 2, parts[0] == today {
        let n = (Int(parts[1]) ?? 0) + 1
        try? "\(today) \(n)".write(toFile: countPath, atomically: true, encoding: .utf8)
        repLabel = "rep \(n) hoy"
    }
}
if repLabel.isEmpty {
    let today = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
    try? "\(today) 1".write(toFile: countPath, atomically: true, encoding: .utf8)
    repLabel = "rep 1 hoy"
}

// Mode from launch args: breath (default) | stand | change | test | mission
let mode = args.count > 1 ? args[1] : "breath"
let missionText = args.count > 2 ? args[2] : ""
let guided = (mode != "test")
let bodyLine = mode == "change"
    ? "🔄 cambia posición — desmonta las caderas"
    : mode == "stand"
    ? "🧍 párate — 10 pasos y hombros"
    : mode == "mission"
    ? missionText
    : ""

// Streak label (written by the metronome script on each launch)
var streakLabel = ""
if let sd = fm.contents(atPath: stateDir + "/ancla-streak"),
   let s = String(data: sd, encoding: .utf8) {
    let p = s.split(separator: " ")
    if p.count == 2, Int(p[0]) ?? 0 > 1 { streakLabel = " · racha \(p[0])d" }
}

// Log one line per rep (read by the Sunday periscope)
func appendLine(_ line: String, to path: String) {
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
let logPath = stateDir + "/ancla-log.csv"
let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
appendLine("\(stamp),\(mode)\n", to: logPath)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.activate(ignoringOtherApps: true)

let screenFrame = NSScreen.main!.frame
let window = KeyWindow(
    contentRect: screenFrame,
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)
window.level = .screenSaver
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
window.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)

// Layout: corner labels + center stack + breathing circle
let meta = NSTextField(labelWithString: "⚓ ancla · \(repLabel)\(streakLabel)")
meta.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
meta.textColor = NSColor(red: 0.42, green: 0.40, blue: 0.36, alpha: 1)
meta.frame = NSRect(x: 28, y: screenFrame.height - 44, width: 300, height: 20)

let hint = NSTextField(labelWithString: "ESC o clic cierra")
hint.font = NSFont.systemFont(ofSize: 14)
hint.textColor = NSColor(red: 0.42, green: 0.40, blue: 0.36, alpha: 1)
hint.alignment = .right
hint.frame = NSRect(x: screenFrame.width - 328, y: screenFrame.height - 44, width: 300, height: 20)

let body = NSTextField(labelWithString: bodyLine)
body.font = NSFont.systemFont(ofSize: 24, weight: .semibold)
body.textColor = NSColor(red: 0.85, green: 0.80, blue: 0.70, alpha: 1)
body.alignment = .center

let phaseTitle = NSTextField(labelWithString: "presiona")
phaseTitle.font = NSFont.systemFont(ofSize: 34, weight: .semibold)
phaseTitle.textColor = NSColor(red: 0.72, green: 0.70, blue: 0.64, alpha: 1)

let circle = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
circle.wantsLayer = true
circle.layer?.backgroundColor = NSColor(red: 0.50, green: 0.82, blue: 0.72, alpha: 0.92).cgColor
circle.layer?.cornerRadius = 120

// Bottom recipe row: what this rep includes
let icons = NSTextField(labelWithString: "🤏")
icons.font = NSFont.systemFont(ofSize: 38)
icons.alignment = .center
switch mode {
case "stand": icons.stringValue = "🤏   🧍   🚶"
case "change": icons.stringValue = "🤏   🔄   🪑"
case "test": icons.stringValue = "🤏   ❓"
default: icons.stringValue = "🤏"
}

let stack = NSStackView()
stack.orientation = .vertical
stack.alignment = .centerX
stack.spacing = 22
stack.translatesAutoresizingMaskIntoConstraints = false
if !bodyLine.isEmpty { stack.addArrangedSubview(body) }
stack.addArrangedSubview(phaseTitle)
stack.addArrangedSubview(circle)
stack.addArrangedSubview(icons)

// widen-the-gaze field — visible only during "ensancha": hearts connected to
// each other and to the forest. soft-focus alpha so it reads as a forest, not icons.
let field = NSTextField(labelWithString: "💚  💚  💚  💚  💚  💚\n  🌲    🌲    🌲    🌲\n💚  💚  💚  💚  💚  💚")
field.font = NSFont.systemFont(ofSize: 30)
field.alignment = .center
field.alphaValue = 0.0
field.translatesAutoresizingMaskIntoConstraints = false
window.contentView!.addSubview(field, positioned: .below, relativeTo: stack)
NSLayoutConstraint.activate([
    field.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
    field.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
])

window.contentView!.addSubview(meta)
window.contentView!.addSubview(hint)

let circleSize: CGFloat = 240
let circleMin: CGFloat = 90
var circleConstraint = circle.widthAnchor.constraint(equalToConstant: circleSize)
let circleHeight = circle.heightAnchor.constraint(equalToConstant: circleSize)
NSLayoutConstraint.activate([
    stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
    stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
    circleConstraint, circleHeight,
    circle.widthAnchor.constraint(equalTo: circle.heightAnchor),
])

// Timeline: A presiona (0–2.5) · B exhala (2.5–9.5, deflate) · C ensancha (9.5–12.5, expand) · D tempo (12.5–15)
// Test mode: no guidance — he leads the cycle himself (prompt fading)
if !guided {
    phaseTitle.stringValue = "haz el ciclo — tú diriges"
    circleConstraint.constant = 165
    circleHeight.constant = 165
    circle.layer?.cornerRadius = 82.5
}
let start = Date()
let tick = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
    let t = Date().timeIntervalSince(start)
    if t >= totalSeconds { app.terminate(nil); return }
    if !guided { return }

    if t < 2.5 {
        phaseTitle.stringValue = "presiona"
        let pulse = circleMin + (circleSize - circleMin) * 0.25
        circleConstraint.constant = pulse
        circleHeight.constant = pulse
    } else if t < 9.5 {
        let p = (t - 2.5) / 7.0 // 0 → 1 across the exhale
        phaseTitle.stringValue = "exhala"
        let v = circleSize - (circleSize - circleMin) * CGFloat(p)
        circleConstraint.constant = v
        circleHeight.constant = v
    } else if t < 12.5 {
        let p = (t - 9.5) / 3.0
        phaseTitle.stringValue = "ensancha"
        let v = circleMin + (circleSize - circleMin) * CGFloat(p)
        circleConstraint.constant = v
        circleHeight.constant = v
        field.alphaValue = 0.85 * CGFloat(p) // gaze widens: the field surfaces
    } else {
        phaseTitle.stringValue = "gente, lento"
        field.alphaValue = 0.85 * max(0, 1 - (t - 12.5) / 2.5) // holds then fades
    }
    circle.layer?.cornerRadius = circleConstraint.constant / 2
}
RunLoop.main.add(tick, forMode: .common)

let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
    if e.keyCode == 53 { app.terminate(nil) }
    return e
}
let clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { _ in
    app.terminate(nil)
    return nil
}

window.makeKeyAndOrderFront(nil)
app.run()
