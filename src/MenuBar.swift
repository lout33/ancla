import AppKit

final class MenuBar: NSObject, NSMenuDelegate {
    private let scheduler: Scheduler
    private var store: Store { scheduler.store }
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    init(scheduler: Scheduler) {
        self.scheduler = scheduler
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refreshTitle()
    }

    func refreshTitle() {
        let s = store.state
        let title: String
        if scheduler.showing {
            title = "⚓"
        } else if s.lastFailure != nil {
            title = "⚓ !"
        } else if s.isPaused {
            title = "⚓ ‖"
        } else if let last = s.lastRep {
            let m = Int(Date().timeIntervalSince(last) / 60)
            title = m < 120 ? "⚓ \(m)m" : m < 24 * 60 ? "⚓ \(m / 60)h" : "⚓"
        } else {
            title = "⚓"
        }
        if item.button?.title != title { item.button?.title = title }
    }

    // Rebuilt on every open so the lines are always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let s = store.state
        menu.removeAllItems()

        menu.addItem(info(StatusText.summary(s)))
        menu.addItem(info(StatusText.schedule(s, showing: scheduler.showing, away: Presence.away)))
        if let failure = s.lastFailure {
            menu.addItem(action("⚠︎ \(failure) — dismiss", #selector(clearFailure)))
        }
        menu.addItem(.separator())

        menu.addItem(action("Fire now", #selector(fireNow)))
        if s.isPaused {
            menu.addItem(action("Resume", #selector(resume)))
        } else {
            let pause = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            sub.addItem(pauseItem("30 min", minutes: 30))
            sub.addItem(pauseItem("1 hour", minutes: 60))
            sub.addItem(pauseItem("2 hours", minutes: 120))
            sub.addItem(pauseItem("until tomorrow (\(Day.time(Day.tomorrowMorning())))", minutes: -1))
            sub.addItem(pauseItem("until I resume", minutes: -2))
            pause.submenu = sub
            menu.addItem(pause)
        }

        let rhythm = NSMenuItem(title: "Rhythm", action: nil, keyEquivalent: "")
        let rsub = NSMenu()
        rsub.autoenablesItems = false
        for r in Rhythm.allCases {
            let mi = action(r.label, #selector(pickRhythm(_:)))
            mi.representedObject = r.rawValue
            mi.state = r == s.rhythm ? .on : .off
            rsub.addItem(mi)
        }
        rhythm.submenu = rsub
        menu.addItem(rhythm)
        menu.addItem(.separator())

        let mission = store.mission
        menu.addItem(action(mission.isEmpty ? "Today's mission…" : "Mission: \(truncate(mission, 40))",
                            #selector(editMission)))
        menu.addItem(action("View rep log", #selector(openRepLog)))
        menu.addItem(action("View events (diagnostics)", #selector(openEvents)))
        menu.addItem(.separator())
        menu.addItem(action("Quit Ancla", #selector(quit)))
    }

    // MARK: - Items

    private func info(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        mi.target = self
        return mi
    }

    private func pauseItem(_ title: String, minutes: Int) -> NSMenuItem {
        let mi = action(title, #selector(pauseFor(_:)))
        mi.tag = minutes
        return mi
    }

    private func truncate(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }

    // MARK: - Actions

    @objc private func fireNow() { scheduler.fire(reason: "menu") }
    @objc private func resume() { scheduler.resume() }
    @objc private func clearFailure() { scheduler.clearFailure() }

    @objc private func pauseFor(_ sender: NSMenuItem) {
        switch sender.tag {
        case -1: scheduler.pause(until: Day.tomorrowMorning())
        case -2: scheduler.pause(until: .distantFuture)
        default: scheduler.pause(until: Date().addingTimeInterval(Double(sender.tag) * 60))
        }
    }

    @objc private func pickRhythm(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let r = Rhythm(rawValue: raw) else { return }
        scheduler.setRhythm(r)
    }

    @objc private func editMission() {
        let alert = NSAlert()
        alert.messageText = "Today's mission"
        alert.informativeText = "Shows on the next rep. Leave empty to skip missions."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.stringValue = store.mission
        field.placeholderString = "one line — what calm-you already decided"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            store.setMission(field.stringValue)
            Log.event("mission set: \(field.stringValue.isEmpty ? "(none)" : field.stringValue)")
        }
    }

    @objc private func openRepLog() { open(Paths.repLog) }
    @objc private func openEvents() { open(Paths.events) }

    private func open(_ path: String) {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: textEdit,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func quit() {
        Log.event("quit from menu")
        scheduler.overlay?.cancel()
        NSApp.terminate(nil)
    }
}
