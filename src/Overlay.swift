import AppKit

// The overlay CONDUCTS the anchor cycle:
// presiona → exhala (guided deflate) → ensancha (expand) → gente, lento.
// Mode "sit" is a 5-minute breath sit instead: follow the circle, press
// space each time you notice you drifted, end with one word.

enum OverlayOutcome {
    case completed
    case dismissed(after: TimeInterval, by: String)

    var logValue: String {
        switch self {
        case .completed: return "completed"
        case .dismissed(let t, let by): return "closed with \(by) at \(Int(t))s"
        }
    }
}

enum Intention {
    /// Picked at random for now; meant to become smarter later.
    static let all = ["understand", "connect", "express clearly", "set a boundary", "enjoy the moment"]
    static func random() -> String { all.randomElement() ?? all[0] }
}

struct OverlayContent {
    /// breath | stand | change | test | mission | sit
    var mode: String
    var mission: String
    /// Top-left label, e.g. "⚓ ancla · rep 3 hoy · racha 2d".
    var meta: String
    var intention: String = Intention.random()
    /// "practice" when the line comes from the if-thens file.
    var intentionTitle = "intention"
    /// morning | night | manual, for sits only.
    var sitKind = ""
}

/// Non-activating so the overlay can take keyboard focus (ESC) without
/// stealing activation from the app you were in; focus returns to it on close.
final class OverlayPanel: NSPanel {
    var onEscape: () -> Void = {}
    override var canBecomeKey: Bool { true }
    // ESC is routed through cancelOperation rather than keyDown in panels.
    override func cancelOperation(_ sender: Any?) { onEscape() }
}

final class Overlay {
    static let duration: TimeInterval = 15
    /// ANCLA_SIT_SECONDS shortens a sit for previews and testing.
    static let sitDuration: TimeInterval = {
        if let v = ProcessInfo.processInfo.environment["ANCLA_SIT_SECONDS"], let n = Double(v), n >= 5 { return n }
        return 300
    }()
    private static let sitWordPhase: TimeInterval = 30
    /// Keys that land right as the overlay appears are the user finishing
    /// what they were doing, not a decision to skip the rep.
    private static let dismissGrace: TimeInterval = 1.5
    /// Clicks get longer: most v2 reps were closed by a click within 2 s,
    /// i.e. reflexively, before the rep could do anything.
    private static let clickGrace: TimeInterval = 5
    private static let circleMax: CGFloat = 240
    private static let circleMin: CGFloat = 90

    private static let background = NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)
    private static let dim = NSColor(red: 0.42, green: 0.40, blue: 0.36, alpha: 1)

    let content: OverlayContent
    private let onFinish: (OverlayOutcome) -> Void
    private var panels: [OverlayPanel] = []
    private var monitors: [Any] = []
    private var timer: Timer?
    private var start = Date()
    private var done = false
    private var previousApp: NSRunningApplication?
    /// Set when this rep paused someone's media; resumed on finish.
    private(set) var pausedMedia: Media.NowPlaying?

    private let phaseTitle = NSTextField(labelWithString: "press")
    private let circle = NSView()
    private var circleWidth: NSLayoutConstraint?
    private var circleHeight: NSLayoutConstraint?
    private let field = NSTextField(labelWithString: "💚  💚  💚  💚  💚  💚\n  🌲    🌲    🌲    🌲\n💚  💚  💚  💚  💚  💚")

    private let hint = NSTextField(labelWithString: "")
    private let clock = NSTextField(labelWithString: "")
    private let returnsLabel = NSTextField(labelWithString: "")
    private let wordPrompt = NSTextField(labelWithString: "what's here? one word")
    private let wordField = NSTextField(string: "")
    private var wordPhase = false
    private weak var primaryPanel: OverlayPanel?
    /// Times you noticed you drifted and came back (space bar).
    private(set) var sitReturns = 0
    private(set) var sitWord = ""

    private var guided: Bool { content.mode != "test" }
    private var isSit: Bool { content.mode == "sit" }
    private var length: TimeInterval { isSit ? Overlay.sitDuration : Overlay.duration }

    init(content: OverlayContent, onFinish: @escaping (OverlayOutcome) -> Void) {
        self.content = content
        self.onFinish = onFinish
    }

    var isOnScreen: Bool { panels.contains { $0.isVisible } }

    func show() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        pausedMedia = Media.pauseIfPlaying()
        let mouse = NSEvent.mouseLocation
        let primary = screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? screens[0]

        for screen in screens {
            let panel = makePanel(for: screen)
            panel.onEscape = { [weak self] in self?.dismiss(by: "esc") }
            if screen == primary {
                if isSit { buildSitContent(in: panel.contentView!) } else { buildContent(in: panel.contentView!) }
                primaryPanel = panel
            }
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        // Take keyboard focus so ESC works and typing does not land blindly in
        // the app underneath; focus is handed back on finish.
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        primaryPanel?.makeKeyAndOrderFront(nil)

        start = Date()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()

        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard let self else { return nil }
            if e.keyCode == 53 { self.dismiss(by: "esc"); return nil }
            guard self.isSit else { return nil }
            if self.wordPhase {
                // Return/Enter ends the sit; everything else types the word.
                if e.keyCode == 36 || e.keyCode == 76 { self.finish(.completed); return nil }
                return e
            }
            if e.keyCode == 49 { self.markReturn() }
            return nil
        }) { monitors.append(m) }
        // A sit is ended deliberately (ESC), never by a stray click.
        if !isSit, let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.dismiss(by: "click")
            return nil
        }) { monitors.append(m) }
    }

    /// Ends the rep early, e.g. when quitting the app mid-rep.
    func cancel() { finish(.dismissed(after: Date().timeIntervalSince(start), by: "quit")) }

    private func dismiss(by: String) {
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed >= (by == "click" ? Overlay.clickGrace : Overlay.dismissGrace) else { return }
        finish(.dismissed(after: elapsed, by: by))
    }

    private func finish(_ outcome: OverlayOutcome) {
        guard !done else { return }
        done = true
        sitWord = wordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panels.forEach { $0.orderOut(nil) }
        panels = []
        if let prev = previousApp, prev != NSRunningApplication.current {
            prev.activate()
        }
        previousApp = nil
        if pausedMedia != nil { Media.resume() }
        onFinish(outcome)
    }

    // MARK: - Layout

    private func makePanel(for screen: NSScreen) -> OverlayPanel {
        let panel = OverlayPanel(contentRect: screen.frame,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.setFrame(screen.frame, display: false)
        // isFloatingPanel resets the level, so it must be set first.
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = Overlay.background
        panel.isOpaque = true
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        setLabel(l, text, font: font, color: color)
        return l
    }

    private func setLabel(_ l: NSTextField, _ text: String, font: NSFont, color: NSColor) {
        l.stringValue = text
        l.font = font
        l.textColor = color
        l.translatesAutoresizingMaskIntoConstraints = false
    }

    private func buildSitContent(in view: NSView) {
        let meta = label(content.meta,
                         font: .monospacedDigitSystemFont(ofSize: 14, weight: .medium), color: Overlay.dim)
        setLabel(hint, "space = I drifted and came back · ESC ends the sit",
                 font: .systemFont(ofSize: 14), color: Overlay.dim)

        let title = NSTextField(labelWithString: "follow the circle")
        title.font = .systemFont(ofSize: 22, weight: .medium)
        title.textColor = Overlay.dim

        phaseTitle.font = .systemFont(ofSize: 34, weight: .semibold)
        phaseTitle.textColor = NSColor(red: 0.72, green: 0.70, blue: 0.64, alpha: 1)
        phaseTitle.alignment = .center
        phaseTitle.stringValue = "in"

        circle.wantsLayer = true
        circle.layer?.backgroundColor = NSColor(red: 0.50, green: 0.82, blue: 0.72, alpha: 0.92).cgColor
        circle.translatesAutoresizingMaskIntoConstraints = false
        let w = circle.widthAnchor.constraint(equalToConstant: Overlay.circleMin)
        let h = circle.heightAnchor.constraint(equalToConstant: Overlay.circleMin)
        circleWidth = w
        circleHeight = h
        circle.layer?.cornerRadius = Overlay.circleMin / 2
        // Fixed-size holder so the breathing circle does not shift the layout.
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(circle)

        returnsLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        returnsLabel.textColor = Overlay.dim
        returnsLabel.stringValue = "returns 0"

        wordPrompt.font = .systemFont(ofSize: 22, weight: .medium)
        wordPrompt.textColor = NSColor(red: 0.85, green: 0.80, blue: 0.70, alpha: 1)
        wordPrompt.isHidden = true
        wordField.font = .systemFont(ofSize: 24)
        wordField.alignment = .center
        wordField.isBordered = false
        wordField.focusRingType = .none
        wordField.drawsBackground = true
        wordField.backgroundColor = NSColor(white: 0.12, alpha: 1)
        wordField.textColor = NSColor(red: 0.85, green: 0.80, blue: 0.70, alpha: 1)
        wordField.placeholderString = "Enter to finish"
        wordField.isHidden = true
        wordField.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, phaseTitle, holder, returnsLabel, wordPrompt, wordField])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        view.addSubview(meta)
        view.addSubview(hint)
        addClock(to: view)

        NSLayoutConstraint.activate([
            w, h,
            holder.widthAnchor.constraint(equalToConstant: Overlay.circleMax),
            holder.heightAnchor.constraint(equalToConstant: Overlay.circleMax),
            circle.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            circle.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            wordField.widthAnchor.constraint(equalToConstant: 320),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            meta.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            meta.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            hint.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
        ])
    }

    /// Time left, top centre, so a rep or sit never leaves you guessing how long it lasts.
    private func addClock(to view: NSView) {
        clock.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        clock.textColor = NSColor(red: 0.85, green: 0.80, blue: 0.70, alpha: 1)
        clock.alignment = .center
        clock.translatesAutoresizingMaskIntoConstraints = false
        clock.stringValue = Overlay.clockText(length)
        view.addSubview(clock)
        NSLayoutConstraint.activate([
            clock.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            clock.topAnchor.constraint(equalTo: view.topAnchor, constant: 40),
        ])
    }

    static func clockText(_ remaining: TimeInterval) -> String {
        let n = Int(max(0, remaining).rounded(.up))
        return String(format: "%d:%02d", n / 60, n % 60)
    }

    private func markReturn() {
        sitReturns += 1
        returnsLabel.stringValue = "returns \(sitReturns)"
    }

    private func buildContent(in view: NSView) {
        let meta = label(content.meta,
                         font: .monospacedDigitSystemFont(ofSize: 14, weight: .medium), color: Overlay.dim)
        setLabel(hint, "ESC closes · click after 5 s", font: .systemFont(ofSize: 14), color: Overlay.dim)

        let bodyText: String
        switch content.mode {
        case "change": bodyText = "🔄 change position — unstick the hips"
        case "stand": bodyText = "🧍 stand — 10 steps + shoulders"
        case "mission": bodyText = content.mission
        default: bodyText = ""
        }
        let body = NSTextField(wrappingLabelWithString: bodyText)
        body.font = .systemFont(ofSize: 24, weight: .semibold)
        body.textColor = NSColor(red: 0.85, green: 0.80, blue: 0.70, alpha: 1)
        body.alignment = .center
        body.preferredMaxLayoutWidth = 760
        body.translatesAutoresizingMaskIntoConstraints = false

        phaseTitle.font = .systemFont(ofSize: 34, weight: .semibold)
        phaseTitle.textColor = NSColor(red: 0.72, green: 0.70, blue: 0.64, alpha: 1)
        phaseTitle.alignment = .center

        circle.wantsLayer = true
        circle.layer?.backgroundColor = NSColor(red: 0.50, green: 0.82, blue: 0.72, alpha: 0.92).cgColor
        circle.translatesAutoresizingMaskIntoConstraints = false
        let start: CGFloat = guided ? Overlay.circleMax : 165
        let w = circle.widthAnchor.constraint(equalToConstant: start)
        let h = circle.heightAnchor.constraint(equalToConstant: start)
        circleWidth = w
        circleHeight = h
        circle.layer?.cornerRadius = start / 2

        let icons = NSTextField(labelWithString: {
            switch content.mode {
            case "stand": return "🤏   🧍   🚶"
            case "change": return "🤏   🔄   🪑"
            case "test": return "🤏   ❓"
            default: return "🤏"
            }
        }())
        icons.font = .systemFont(ofSize: 38)
        icons.alignment = .center

        if !guided { phaseTitle.stringValue = "run the cycle — you lead" }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        if !bodyText.isEmpty { stack.addArrangedSubview(body) }
        stack.addArrangedSubview(phaseTitle)
        stack.addArrangedSubview(circle)
        stack.addArrangedSubview(icons)

        let intentionTitle = NSTextField(labelWithString: content.intentionTitle)
        intentionTitle.font = .systemFont(ofSize: 14, weight: .medium)
        intentionTitle.textColor = Overlay.dim
        let intention = NSTextField(labelWithString: content.intention)
        intention.font = .systemFont(ofSize: 28, weight: .semibold)
        intention.textColor = NSColor(red: 0.85, green: 0.80, blue: 0.70, alpha: 1)
        stack.addArrangedSubview(intentionTitle)
        stack.addArrangedSubview(intention)
        stack.setCustomSpacing(40, after: icons)
        stack.setCustomSpacing(6, after: intentionTitle)

        // widen-the-gaze field: surfaces only during "ensancha", soft alpha so
        // it reads as a forest, not icons.
        field.font = .systemFont(ofSize: 30)
        field.alignment = .center
        field.alphaValue = 0
        field.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(field)
        view.addSubview(stack)
        view.addSubview(meta)
        view.addSubview(hint)
        addClock(to: view)

        NSLayoutConstraint.activate([
            w, h,
            body.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            field.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            meta.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            meta.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            hint.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
        ])
    }

    // MARK: - Timeline
    /// press 0–2.5 · exhale 2.5–9.5 (deflate) · widen 9.5–12.5 (expand) · people, slow 12.5–15

    private func setCircle(_ size: CGFloat) {
        circleWidth?.constant = size
        circleHeight?.constant = size
        circle.layer?.cornerRadius = size / 2
    }

    private func tick() {
        let t = Date().timeIntervalSince(start)
        if t >= length { finish(.completed); return }
        clock.stringValue = Overlay.clockText(length - t)
        if isSit { sitTick(t); return }
        guard guided else { return }

        let span = Overlay.circleMax - Overlay.circleMin
        if t < 2.5 {
            phaseTitle.stringValue = "press"
            setCircle(Overlay.circleMin + span * 0.25)
        } else if t < 9.5 {
            phaseTitle.stringValue = "exhale"
            setCircle(Overlay.circleMax - span * CGFloat((t - 2.5) / 7.0))
        } else if t < 12.5 {
            let p = CGFloat((t - 9.5) / 3.0)
            phaseTitle.stringValue = "widen"
            setCircle(Overlay.circleMin + span * p)
            field.alphaValue = 0.85 * p
        } else {
            phaseTitle.stringValue = "people, slow"
            field.alphaValue = 0.85 * max(0, 1 - CGFloat((t - 12.5) / 2.5))
        }
    }

    /// Sit timeline: breathe 4 s in, 6 s out (a slow exhale, about 6 breaths
    /// a minute); the last 30 s ask for one word.
    private func sitTick(_ t: TimeInterval) {
        let span = Overlay.circleMax - Overlay.circleMin
        let c = t.truncatingRemainder(dividingBy: 10)
        if c < 4 {
            phaseTitle.stringValue = "in"
            setCircle(Overlay.circleMin + span * CGFloat(c / 4))
        } else {
            phaseTitle.stringValue = "out"
            setCircle(Overlay.circleMax - span * CGFloat((c - 4) / 6))
        }
        if !wordPhase, t >= length - min(Overlay.sitWordPhase, length * 0.3) {
            wordPhase = true
            wordPrompt.isHidden = false
            wordField.isHidden = false
            hint.stringValue = "type one word · Enter finishes · ESC ends"
            primaryPanel?.makeFirstResponder(wordField)
        }
    }
}
