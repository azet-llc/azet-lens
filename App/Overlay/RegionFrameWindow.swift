import AppKit
import QuartzCore

/// The draggable "lens" around a region: a glowing, slowly turning gradient ring (in the colours of Apple
/// Intelligence) that brightens while the lens reads and translates, a name pill on top, and a resize corner.
/// The ring and pill are grabbable; the interior is fully transparent, so clicks there go to the app underneath.
final class RegionFrameWindow: NSPanel {
    /// Room around the region for the glow and the grab band.
    static let margin: CGFloat = 18
    static let tabHeight: CGFloat = 26

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
               width: region.width + 2 * margin, height: region.height + margin + tabHeight + 6)
    }

    var regionFrame: NSRect {
        NSRect(x: frame.minX + Self.margin, y: frame.minY + Self.margin,
               width: frame.width - 2 * Self.margin, height: frame.height - Self.margin - Self.tabHeight - 6)
    }

    func setRegion(_ r: NSRect) {
        setFrame(Self.windowFrame(for: r), display: true)
    }

    func setName(_ name: String) { chrome.name = name }
    /// Second line of the pill, e.g. "영어 → 한국어".
    func setDetail(_ detail: String) { chrome.detail = detail }

    /// Handles and full brightness while the pointer is near or a drag is in progress.
    func setEmphasized(_ on: Bool) { chrome.setEmphasized(on) }

    func setBusy(_ busy: Bool) { chrome.busy = busy }

    /// A light sweep across the lens, for when it first comes alive.
    func sweep() { chrome.sweep() }
}

private final class FrameChromeView: NSView {
    weak var window_: RegionFrameWindow?
    var name: String { didSet { needsDisplay = true } }
    var detail = "" { didSet { needsDisplay = true } }
    var busy = false { didSet { if busy != oldValue { updateGlow(); needsDisplay = true } } }

    private enum Drag { case move, resize }
    private var drag: Drag?
    private var startMouse: NSPoint = .zero
    private var startRegion: NSRect = .zero
    private var emphasized = false
    private var hovering = false
    private var tracking: NSTrackingArea?

    private let band: CGFloat = 10         // grabbable width of the ring
    private let corner: CGFloat = 20       // resize handle size
    private let radius: CGFloat = 12

    // Ring: a conic gradient spinning inside a stroke-shaped mask; the glow is a wider, blurred copy.
    private let ring = CALayer(), ringMask = CAShapeLayer(), ringGradient = CAGradientLayer()
    private let glow = CALayer(), glowMask = CAShapeLayer(), glowGradient = CAGradientLayer()
    private let sweepClip = CALayer(), sweepMask = CAShapeLayer(), sweepLayer = CAGradientLayer()

    private static let colors: [CGColor] = [
        NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1), // orange
        NSColor(srgbRed: 1.00, green: 0.22, blue: 0.37, alpha: 1), // pink
        NSColor(srgbRed: 0.75, green: 0.35, blue: 0.95, alpha: 1), // purple
        NSColor(srgbRed: 0.37, green: 0.36, blue: 0.90, alpha: 1), // indigo
        NSColor(srgbRed: 0.39, green: 0.82, blue: 1.00, alpha: 1), // cyan
        NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1),
    ].map(\.cgColor)

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        for (container, mask, gradient) in [(glow, glowMask, glowGradient), (ring, ringMask, ringGradient)] {
            gradient.type = .conic
            gradient.colors = Self.colors
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            mask.fillColor = nil
            mask.strokeColor = NSColor.black.cgColor
            container.mask = mask
            container.addSublayer(gradient)
            layer?.addSublayer(container)
        }
        ringMask.lineWidth = 2.5
        glowMask.lineWidth = 10
        glow.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 9])!]
        sweepLayer.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.22).cgColor,
                             NSColor.white.withAlphaComponent(0).cgColor]
        sweepLayer.startPoint = CGPoint(x: 0, y: 0.5)
        sweepLayer.endPoint = CGPoint(x: 1, y: 0.5)
        sweepLayer.opacity = 0
        sweepClip.mask = sweepMask
        sweepClip.addSublayer(sweepLayer)
        layer?.addSublayer(sweepClip)
        updateGlow()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setEmphasized(_ on: Bool) {
        guard on != emphasized else { return }
        emphasized = on
        updateGlow()
        needsDisplay = true
    }

    // MARK: - Geometry (view coordinates, y up)

    private var regionRect: NSRect {
        NSRect(x: RegionFrameWindow.margin, y: RegionFrameWindow.margin,
               width: bounds.width - 2 * RegionFrameWindow.margin,
               height: bounds.height - RegionFrameWindow.margin - RegionFrameWindow.tabHeight - 6)
    }

    private var strong: Bool { emphasized || hovering || drag != nil }

    private var tabRect: NSRect {
        let title = (name as NSString).size(withAttributes: [.font: Self.titleFont]).width
        let sub = detail.isEmpty ? 0 : (detail as NSString).size(withAttributes: [.font: Self.detailFont]).width + 10
        let w = min(regionRect.width, title + sub + 40 + (strong ? 22 : 0))
        return NSRect(x: regionRect.minX, y: regionRect.maxY + 6, width: max(72, w), height: RegionFrameWindow.tabHeight)
    }

    private var closeRect: NSRect {
        NSRect(x: tabRect.maxX - 23, y: tabRect.midY - 8, width: 16, height: 16)
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

    // MARK: - Layers

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGPath(roundedRect: regionRect.insetBy(dx: -1, dy: -1), cornerWidth: radius, cornerHeight: radius, transform: nil)
        let diagonal = hypot(bounds.width, bounds.height)
        for (container, mask, gradient) in [(glow, glowMask, glowGradient), (ring, ringMask, ringGradient)] {
            container.frame = bounds
            mask.frame = bounds
            mask.path = path
            // A square big enough to cover the ring at any angle, turning about the lens centre.
            gradient.bounds = CGRect(x: 0, y: 0, width: diagonal, height: diagonal)
            gradient.position = CGPoint(x: regionRect.midX, y: regionRect.midY)
        }
        sweepClip.frame = bounds
        sweepMask.frame = bounds
        sweepLayer.bounds = CGRect(x: 0, y: 0, width: regionRect.width * 0.6, height: regionRect.height)
        sweepLayer.position = CGPoint(x: regionRect.minX - regionRect.width, y: regionRect.midY)
        sweepMask.path = CGPath(roundedRect: regionRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
    }

    /// Calm and slow at rest; brighter and faster while reading or translating, or under the pointer.
    private func updateGlow() {
        let period: CFTimeInterval = busy ? 2.4 : 9
        for gradient in [ringGradient, glowGradient] {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = (gradient.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double) ?? 0
            spin.byValue = -2 * Double.pi
            spin.duration = period
            spin.repeatCount = .infinity
            gradient.add(spin, forKey: "spin")
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        ring.opacity = busy || strong ? 1 : 0.8
        glow.opacity = busy ? 0.95 : strong ? 0.75 : 0.45
        CATransaction.commit()
    }

    func sweep() {
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = regionRect.minX - regionRect.width / 2
        move.toValue = regionRect.maxX + regionRect.width / 2
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.8, 1]
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.9
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweepLayer.add(group, forKey: "sweep")
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
        case .move?: (strong && closeRect.contains(p) ? NSCursor.arrow : NSCursor.openHand).set()
        case nil: NSCursor.arrow.set()
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateGlow(); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; updateGlow(); needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if strong, closeRect.contains(p) { window_?.onClose?(); return }
        drag = zone(at: p)
        startMouse = NSEvent.mouseLocation
        startRegion = window_?.regionFrame ?? .zero
        if drag == .move { NSCursor.closedHand.set() }
        updateGlow()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let w = window_ else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - startMouse.x, dy = m.y - startMouse.y
        switch drag {
        case .move:
            var r = startRegion.offsetBy(dx: dx, dy: dy)
            // Keep the lens on its screen: the capture cannot span displays.
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: startRegion.midX, y: startRegion.midY)) }) {
                let f = screen.frame
                r.origin.x = min(max(r.minX, f.minX), f.maxX - r.width)
                r.origin.y = min(max(r.minY, f.minY), f.maxY - r.height)
            }
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
        updateGlow()
        needsDisplay = true
        window_?.onCommit?()
    }

    // MARK: - Drawing (pill, handles)

    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let detailFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    override func draw(_ dirtyRect: NSRect) {
        let r = regionRect
        // An almost invisible band makes the ring grabbable; the interior stays alpha 0 (click-through).
        let bandPath = NSBezierPath(roundedRect: r.insetBy(dx: -band / 2, dy: -band / 2), xRadius: radius + 4, yRadius: radius + 4)
        bandPath.append(NSBezierPath(roundedRect: r.insetBy(dx: band / 2, dy: band / 2), xRadius: radius - 4, yRadius: radius - 4).reversed)
        NSColor.black.withAlphaComponent(0.004).setFill()
        bandPath.fill()

        // Name pill: dark glass with a gradient dot that pulses while busy.
        let tab = tabRect
        let pill = NSBezierPath(roundedRect: tab, xRadius: tab.height / 2, yRadius: tab.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor(white: 0.08, alpha: strong ? 0.88 : 0.72).setFill()
        pill.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        pill.lineWidth = 0.5
        pill.stroke()

        let dot = NSRect(x: tab.minX + 11, y: tab.midY - 4.5, width: 9, height: 9)
        NSGradient(colors: Self.colors.prefix(4).compactMap { NSColor(cgColor: $0) })?
            .draw(in: NSBezierPath(ovalIn: dot), angle: busy ? 90 : -45)

        var x = dot.maxX + 8
        let title = NSAttributedString(string: name, attributes: [.font: Self.titleFont, .foregroundColor: NSColor.white])
        let limit = tab.maxX - x - (strong ? 28 : 12)
        title.draw(with: NSRect(x: x, y: tab.midY - title.size().height / 2 + 1, width: limit, height: title.size().height),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        x += title.size().width + 10
        if !detail.isEmpty, x < tab.maxX - 30 {
            let sub = NSAttributedString(string: busy ? "번역 중…" : detail,
                                         attributes: [.font: Self.detailFont, .foregroundColor: NSColor.white.withAlphaComponent(0.6)])
            sub.draw(with: NSRect(x: x, y: tab.midY - sub.size().height / 2 + 1, width: tab.maxX - x - (strong ? 28 : 10),
                                  height: sub.size().height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        guard strong else { return }
        if let xmark = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "닫기")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) {
            xmark.tinted(.white.withAlphaComponent(0.8)).draw(in: closeRect)
        }

        // Resize grip: two short diagonal strokes in the corner.
        let g = NSBezierPath()
        let c = NSPoint(x: r.maxX - 4, y: r.minY + 4)
        for d in [CGFloat(7), 12] {
            g.move(to: NSPoint(x: c.x - d, y: c.y))
            g.line(to: NSPoint(x: c.x, y: c.y + d))
        }
        g.lineWidth = 2
        g.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke()
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
