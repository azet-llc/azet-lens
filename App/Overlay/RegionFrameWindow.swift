import AppKit

/// The draggable "lens" chrome around a region: a thin border you can grab anywhere, a name tab on top,
/// and a resize corner. Its interior is fully transparent, so clicks there go to the app underneath.
final class RegionFrameWindow: NSPanel {
    static let margin: CGFloat = 8
    static let tabHeight: CGFloat = 24

    /// Live drag: the region's new AppKit frame.
    var onMove: ((NSRect) -> Void)?
    var onResize: ((NSRect) -> Void)?
    /// Drag/resize finished.
    var onCommit: (() -> Void)?
    var onClose: (() -> Void)?

    private let chrome: FrameChromeView

    init(region: NSRect, name: String) {
        chrome = FrameChromeView(name: name)
        super.init(contentRect: Self.windowFrame(for: region), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        contentView = chrome
        chrome.window_ = self
    }

    override var canBecomeKey: Bool { false }

    static func windowFrame(for region: NSRect) -> NSRect {
        NSRect(x: region.minX - margin, y: region.minY - margin,
               width: region.width + 2 * margin, height: region.height + margin + tabHeight + 4)
    }

    var regionFrame: NSRect {
        NSRect(x: frame.minX + Self.margin, y: frame.minY + Self.margin,
               width: frame.width - 2 * Self.margin, height: frame.height - Self.margin - Self.tabHeight - 4)
    }

    func setRegion(_ r: NSRect) {
        setFrame(Self.windowFrame(for: r), display: true)
    }

    func setName(_ name: String) { chrome.name = name }

    /// Fully visible while the pointer is near or a drag is in progress; a faint outline otherwise.
    func setEmphasized(_ on: Bool) { chrome.setEmphasized(on) }

    func setBusy(_ busy: Bool) { chrome.busy = busy }
}

private final class FrameChromeView: NSView {
    weak var window_: RegionFrameWindow?
    var name: String { didSet { needsDisplay = true } }
    var busy = false { didSet { if busy != oldValue { needsDisplay = true } } }

    private enum Drag { case move, resize }
    private var drag: Drag?
    private var startMouse: NSPoint = .zero
    private var startRegion: NSRect = .zero
    private var emphasized = false
    private var hovering = false
    private var tracking: NSTrackingArea?

    private let band: CGFloat = 8          // grabbable width of the border
    private let corner: CGFloat = 18       // resize handle size

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setEmphasized(_ on: Bool) {
        guard on != emphasized else { return }
        emphasized = on
        needsDisplay = true
    }

    // MARK: - Geometry (view coordinates, y up)

    private var regionRect: NSRect {
        NSRect(x: RegionFrameWindow.margin, y: RegionFrameWindow.margin,
               width: bounds.width - 2 * RegionFrameWindow.margin,
               height: bounds.height - RegionFrameWindow.margin - RegionFrameWindow.tabHeight - 4)
    }

    private var tabRect: NSRect {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let w = min(regionRect.width, (name as NSString).size(withAttributes: [.font: font]).width + 58)
        return NSRect(x: regionRect.minX, y: regionRect.maxY + 4, width: max(64, w), height: RegionFrameWindow.tabHeight)
    }

    private var closeRect: NSRect {
        NSRect(x: tabRect.maxX - 22, y: tabRect.minY + 4, width: 16, height: 16)
    }

    private var resizeRect: NSRect {
        NSRect(x: regionRect.maxX - corner + band / 2, y: regionRect.minY - band / 2, width: corner, height: corner)
    }

    private func zone(at p: NSPoint) -> Drag? {
        if resizeRect.contains(p) { return .resize }
        if tabRect.contains(p) { return .move }
        let outer = regionRect.insetBy(dx: -band / 2, dy: -band / 2), inner = regionRect.insetBy(dx: band / 2, dy: band / 2)
        return outer.contains(p) && !inner.contains(p) ? .move : nil
    }

    // MARK: - Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .cursorUpdate], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateCursor(convert(event.locationInWindow, from: nil)) }

    private func updateCursor(_ p: NSPoint) {
        switch zone(at: p) {
        case .resize?: NSCursor.frameResize(position: .bottomRight, directions: .all).set()
        case .move?: (closeRect.contains(p) ? NSCursor.arrow : NSCursor.openHand).set()
        case nil: NSCursor.arrow.set()
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeRect.contains(p) { window_?.onClose?(); return }
        drag = zone(at: p)
        startMouse = NSEvent.mouseLocation
        startRegion = window_?.regionFrame ?? .zero
        if drag == .move { NSCursor.closedHand.set() }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let w = window_ else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - startMouse.x, dy = m.y - startMouse.y
        switch drag {
        case .move:
            let r = startRegion.offsetBy(dx: dx, dy: dy)
            w.setRegion(r)
            w.onMove?(r)
        case .resize:
            // Bottom-right corner: the top-left stays put (in AppKit, top = maxY).
            let width = max(80, startRegion.width + dx), height = max(40, startRegion.height - dy)
            let r = NSRect(x: startRegion.minX, y: startRegion.maxY - height, width: width, height: height)
            w.setRegion(r)
            w.onResize?(r)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        drag = nil
        updateCursor(convert(event.locationInWindow, from: nil))
        needsDisplay = true
        window_?.onCommit?()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let strong = emphasized || hovering || drag != nil
        let accent = NSColor.controlAccentColor
        let r = regionRect

        // An almost invisible band makes the border grabbable; the interior stays alpha 0 (click-through).
        let bandPath = NSBezierPath(roundedRect: r.insetBy(dx: -band / 2, dy: -band / 2), xRadius: 10, yRadius: 10)
        bandPath.append(NSBezierPath(roundedRect: r.insetBy(dx: band / 2, dy: band / 2), xRadius: 4, yRadius: 4).reversed)
        NSColor.black.withAlphaComponent(0.004).setFill()
        bandPath.fill()

        // Visible border.
        let border = NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: 7, yRadius: 7)
        border.lineWidth = strong ? 2 : 1.25
        if strong {
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = accent.withAlphaComponent(0.55)
            glow.shadowBlurRadius = 8
            glow.set()
            accent.setStroke()
            border.stroke()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            accent.withAlphaComponent(0.45).setStroke()
            border.setLineDash([6, 4], count: 2, phase: 0)
            border.stroke()
        }

        guard strong else { return }

        // Name tab.
        let tab = tabRect
        let tabPath = NSBezierPath(roundedRect: tab, xRadius: tab.height / 2, yRadius: tab.height / 2)
        accent.setFill()
        tabPath.fill()
        let icon = NSImage(systemSymbolName: busy ? "ellipsis" : "character.bubble.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        if let icon {
            let tinted = icon.tinted(.white)
            tinted.draw(in: NSRect(x: tab.minX + 9, y: tab.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let label = NSAttributedString(string: name, attributes: attrs)
        let labelRect = NSRect(x: tab.minX + 27, y: tab.midY - label.size().height / 2, width: tab.width - 27 - 26, height: label.size().height)
        label.draw(with: labelRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let x = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "닫기")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) {
            x.tinted(.white.withAlphaComponent(0.85)).draw(in: closeRect)
        }

        // Resize grip: two short diagonal strokes in the corner.
        let g = NSBezierPath()
        let c = NSPoint(x: r.maxX - 3, y: r.minY + 3)
        for d in [CGFloat(7), 12] {
            g.move(to: NSPoint(x: c.x - d, y: c.y))
            g.line(to: NSPoint(x: c.x, y: c.y + d))
        }
        g.lineWidth = 2
        g.lineCapStyle = .round
        accent.setStroke()
        g.stroke()
    }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
