import AppKit

// The overlay CONDUCTS the anchor cycle:
// presiona → exhala (guided deflate) → ensancha (expand) → gente, lento.

enum OverlayOutcome {
    case completed
    case dismissed(after: TimeInterval, by: String)

    var logValue: String {
        switch self {
        case .completed: return "completo"
        case .dismissed(let t, let by): return "cerrado con \(by) a los \(Int(t))s"
        }
    }
}

struct OverlayContent {
    /// breath | stand | change | test | mission
    var mode: String
    var mission: String
    /// Top-left label, e.g. "⚓ ancla · rep 3 hoy · racha 2d".
    var meta: String
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
    /// Clicks and keys that land right as the overlay appears are the user
    /// finishing what they were doing, not a decision to skip the rep.
    private static let dismissGrace: TimeInterval = 1.5
    private static let circleMax: CGFloat = 240
    private static let circleMin: CGFloat = 90

    private static let background = NSColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)
    private static let dim = NSColor(red: 0.42, green: 0.40, blue: 0.36, alpha: 1)

    private let content: OverlayContent
    private let onFinish: (OverlayOutcome) -> Void
    private var panels: [OverlayPanel] = []
    private var monitors: [Any] = []
    private var timer: Timer?
    private var start = Date()
    private var done = false
    private var previousApp: NSRunningApplication?

    private let phaseTitle = NSTextField(labelWithString: "presiona")
    private let circle = NSView()
    private var circleWidth: NSLayoutConstraint?
    private var circleHeight: NSLayoutConstraint?
    private let field = NSTextField(labelWithString: "💚  💚  💚  💚  💚  💚\n  🌲    🌲    🌲    🌲\n💚  💚  💚  💚  💚  💚")

    private var guided: Bool { content.mode != "test" }

    init(content: OverlayContent, onFinish: @escaping (OverlayOutcome) -> Void) {
        self.content = content
        self.onFinish = onFinish
    }

    var isOnScreen: Bool { panels.contains { $0.isVisible } }

    func show() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        let primary = screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? screens[0]

        var primaryPanel: OverlayPanel?
        for screen in screens {
            let panel = makePanel(for: screen)
            panel.onEscape = { [weak self] in self?.dismiss(by: "esc") }
            if screen == primary {
                buildContent(in: panel.contentView!)
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
            if e.keyCode == 53 { self?.dismiss(by: "esc") }
            return nil
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.dismiss(by: "clic")
            return nil
        }) { monitors.append(m) }
    }

    /// Ends the rep early, e.g. when quitting the app mid-rep.
    func cancel() { finish(.dismissed(after: Date().timeIntervalSince(start), by: "salir")) }

    private func dismiss(by: String) {
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed >= Overlay.dismissGrace else { return }
        finish(.dismissed(after: elapsed, by: by))
    }

    private func finish(_ outcome: OverlayOutcome) {
        guard !done else { return }
        done = true
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
        l.font = font
        l.textColor = color
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func buildContent(in view: NSView) {
        let meta = label(content.meta,
                         font: .monospacedDigitSystemFont(ofSize: 14, weight: .medium), color: Overlay.dim)
        let hint = label("ESC o clic cierra", font: .systemFont(ofSize: 14), color: Overlay.dim)

        let bodyText: String
        switch content.mode {
        case "change": bodyText = "🔄 cambia posición — desmonta las caderas"
        case "stand": bodyText = "🧍 párate — 10 pasos y hombros"
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

        if !guided { phaseTitle.stringValue = "haz el ciclo — tú diriges" }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        if !bodyText.isEmpty { stack.addArrangedSubview(body) }
        stack.addArrangedSubview(phaseTitle)
        stack.addArrangedSubview(circle)
        stack.addArrangedSubview(icons)

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
    // presiona 0–2.5 · exhala 2.5–9.5 (deflate) · ensancha 9.5–12.5 (expand) · gente, lento 12.5–15

    private func setCircle(_ size: CGFloat) {
        circleWidth?.constant = size
        circleHeight?.constant = size
        circle.layer?.cornerRadius = size / 2
    }

    private func tick() {
        let t = Date().timeIntervalSince(start)
        if t >= Overlay.duration { finish(.completed); return }
        guard guided else { return }

        let span = Overlay.circleMax - Overlay.circleMin
        if t < 2.5 {
            phaseTitle.stringValue = "presiona"
            setCircle(Overlay.circleMin + span * 0.25)
        } else if t < 9.5 {
            phaseTitle.stringValue = "exhala"
            setCircle(Overlay.circleMax - span * CGFloat((t - 2.5) / 7.0))
        } else if t < 12.5 {
            let p = CGFloat((t - 9.5) / 3.0)
            phaseTitle.stringValue = "ensancha"
            setCircle(Overlay.circleMin + span * p)
            field.alphaValue = 0.85 * p
        } else {
            phaseTitle.stringValue = "gente, lento"
            field.alphaValue = 0.85 * max(0, 1 - CGFloat((t - 12.5) / 2.5))
        }
    }
}
