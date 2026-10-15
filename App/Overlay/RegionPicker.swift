import AppKit

/// Full-screen chooser: drag to select an area, or click a window to take all of it. Esc cancels.
@MainActor
final class RegionPicker {
    struct Result {
        /// Global Quartz points.
        var rect: CGRect
        /// The window the area sits in, if it lies entirely inside one.
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
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                if e.keyCode == 53 { self?.finish(nil); return nil } // esc
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

    private func window(at p: NSPoint) -> WindowInfo? {
        let q = quartz(NSRect(origin: p, size: .zero)).origin
        return windows.first { $0.bounds.contains(q) }
    }

    // MARK: - Events

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let w = window(at: p)
        if w?.id != hovered?.id { hovered = w; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
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
            let container = windows.first { $0.bounds.contains(rect) }
            done(.init(rect: rect, window: container))
        } else if let w = hovered {
            // Click on a window: take the window's content (skip the title bar strip).
            let titleBar: CGFloat = w.bounds.height > 120 ? 28 : 0
            let r = CGRect(x: w.bounds.minX, y: w.bounds.minY + titleBar, width: w.bounds.width, height: w.bounds.height - titleBar)
            let visible = r.intersection(quartz(bounds))
            done(.init(rect: visible.isNull ? r : visible, window: w))
        } else {
            needsDisplay = true
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
            label("\(Int(sel.width)) × \(Int(sel.height))", near: sel)
        } else if let w = hovered {
            let r = local(w.bounds)
            punch(r, radius: 10)
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
            stroke(r, color: .controlAccentColor, width: 3, radius: 10)
            label(w.appName.isEmpty ? String(localized: "Translate this window") : String(localized: "\(w.appName) — click to follow this window"), near: r, inside: true)
        }
        hint()
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
        let text = String(localized: "Drag to place a lens  ·  Click a window to follow it  ·  esc to cancel")
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
