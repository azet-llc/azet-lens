import AppKit

/// Full-screen chooser: drag to select an area, or click to drop a lens of the default size there. A lens that lands
/// in a window follows it; holding ⌥ pins it to the screen instead. A lens never defaults to a whole window: the bigger
/// the area, the slower every read. Esc cancels.
@MainActor
final class RegionPicker {
    struct Result {
        /// Global Quartz points.
        var rect: CGRect
        /// The window to follow: the one the lens landed in, unless ⌥ pinned it to the screen.
        var window: WindowInfo?
    }

    private var windows: [PickerWindow] = []
    private var continuation: CheckedContinuation<Result?, Never>?
    private var keyMonitor: Any?

    func pick() async -> Result? {
        let snapshot = WindowInfo.onScreen()
        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { cont in
            continuation = cont
            for screen in NSScreen.screens {
                let w = PickerWindow(screen: screen, windows: snapshot) { [weak self] result in self?.finish(result) }
                w.orderFrontRegardless()
                windows.append(w)
            }
            let mouse = NSEvent.mouseLocation
            (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
            NSCursor.crosshair.push()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
                if e.type == .keyDown, e.keyCode == 53 { self?.finish(nil); return nil } // esc
                if e.type == .flagsChanged { self?.windows.forEach { $0.contentView?.needsDisplay = true } } // ⌥ flips the label
                return e
            }
        }
    }

    private func finish(_ result: Result?) {
        guard let cont = continuation else { return }
        continuation = nil
        NSCursor.pop()
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        cont.resume(returning: result)
    }
}

private final class PickerWindow: NSWindow {
    init(screen: NSScreen, windows: [WindowInfo], done: @escaping (RegionPicker.Result?) -> Void) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = PickerView(screen: screen, windows: windows, done: done)
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
}

private final class PickerView: NSView {
    private let screenFrame: NSRect
    private let windows: [WindowInfo]
    private let done: (RegionPicker.Result?) -> Void
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var hovered: WindowInfo?
    private var pointer: NSPoint?
    private var tracking: NSTrackingArea?

    init(screen: NSScreen, windows: [WindowInfo], done: @escaping (RegionPicker.Result?) -> Void) {
        self.screenFrame = screen.frame
        self.windows = windows
        self.done = done
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    // MARK: - Coordinates

    private func quartz(_ local: NSRect) -> CGRect {
        ScreenGeometry.quartzRect(fromAppKit: local.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY))
    }

    private func local(_ quartzRect: CGRect) -> NSRect {
        ScreenGeometry.appKitRect(fromQuartz: quartzRect).offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    private var selection: NSRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// ⌥ pins the lens to the screen.
    private var pinned: Bool { NSEvent.modifierFlags.contains(.option) }

    private func window(at p: NSPoint) -> WindowInfo? {
        let q = quartz(NSRect(origin: p, size: .zero)).origin
        return windows.first { $0.bounds.contains(q) }
    }

    /// The lens a click at `p` would drop: a typical chat or comment column, kept inside the window's content and the screen.
    private func clickLens(at p: NSPoint) -> NSRect {
        var area = bounds
        if let w = hovered {
            let titleBar: CGFloat = w.bounds.height > 120 ? 28 : 0
            area = local(w.bounds).intersection(bounds)
            area.size.height -= titleBar // AppKit y is up: the title bar is the top strip
        }
        let size = NSSize(width: min(560, area.width), height: min(320, area.height))
        let x = min(max(p.x - size.width / 2, area.minX), area.maxX - size.width)
        let y = min(max(p.y - size.height / 2, area.minY), area.maxY - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    // MARK: - Events

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hovered = window(at: p)
        pointer = p
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        pointer = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragCurrent = nil }
        if let sel = selection, sel.width >= 24, sel.height >= 12 {
            let rect = quartz(sel)
            // A lens overhanging a window's edge still belongs to it: go by its centre.
            let container = windows.first { $0.bounds.contains(CGPoint(x: rect.midX, y: rect.midY)) }
            done(.init(rect: rect, window: pinned ? nil : container))
        } else {
            let p = convert(event.locationInWindow, from: nil)
            hovered = window(at: p)
            done(.init(rect: quartz(clickLens(at: p)), window: pinned ? nil : hovered))
        }
    }

    override func rightMouseDown(with event: NSEvent) { done(nil) }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill()

        if let sel = selection {
            punch(sel, radius: 4)
            stroke(sel, color: .white, width: 1.5, radius: 4)
            let w = pinned ? nil : window(at: NSPoint(x: sel.midX, y: sel.midY))
            if let w { stroke(local(w.bounds), color: .controlAccentColor.withAlphaComponent(0.5), width: 1.5, radius: 10) }
            label("\(Int(sel.width)) × \(Int(sel.height))  ·  \(mode(w))", near: sel)
        } else if let p = pointer {
            let r = clickLens(at: p)
            let w = pinned ? nil : hovered
            if let w { stroke(local(w.bounds), color: .controlAccentColor.withAlphaComponent(0.5), width: 1.5, radius: 10) }
            punch(r, radius: 10)
            stroke(r, color: .controlAccentColor, width: 3, radius: 10)
            label(mode(w), near: r, inside: true)
        }
        hint()
    }

    /// What the lens will do once placed.
    private func mode(_ w: WindowInfo?) -> String {
        guard let w else { return String(localized: "Pinned to the screen") }
        let app = w.appName.isEmpty ? String(localized: "Window") : w.appName
        return String(localized: "Follows \(app)  ·  ⌥ pins to the screen")
    }

    private func punch(_ r: NSRect, radius: CGFloat) {
        NSGraphicsContext.current?.compositingOperation = .copy
        NSColor.clear.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    private func stroke(_ r: NSRect, color: NSColor, width: CGFloat, radius: CGFloat) {
        let p = NSBezierPath(roundedRect: r.insetBy(dx: -width / 2, dy: -width / 2), xRadius: radius, yRadius: radius)
        p.lineWidth = width
        color.setStroke()
        p.stroke()
    }

    private func label(_ text: String, near r: NSRect, inside: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        let pill = NSSize(width: size.width + 16, height: size.height + 8)
        var origin = inside ? NSPoint(x: r.midX - pill.width / 2, y: r.maxY - pill.height - 12)
            : NSPoint(x: r.maxX - pill.width, y: r.minY - pill.height - 8)
        if origin.y < 4 { origin.y = r.minY + 8 }
        let pr = NSRect(origin: origin, size: pill)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: pr, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        s.draw(at: NSPoint(x: pr.minX + 8, y: pr.minY + 4))
    }

    private func hint() {
        guard screenFrame.contains(NSEvent.mouseLocation) || NSScreen.screens.count == 1 else { return }
        let text = String(localized: "Drag an area or click  ·  ⌥ pins to the screen  ·  esc to cancel")
        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = s.size()
        let pill = NSRect(x: bounds.midX - (size.width + 32) / 2, y: bounds.maxY - 120, width: size.width + 32, height: size.height + 16)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor(white: 0.12, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        s.draw(at: NSPoint(x: pill.minX + 16, y: pill.minY + 8))
    }
}
