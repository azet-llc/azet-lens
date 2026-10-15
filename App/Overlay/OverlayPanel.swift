import AppKit
import QuartzCore

/// Transparent, click-through panel floating over a region. Shows one layer per translated block.
final class OverlayPanel: NSPanel {
    private let host = OverlayHostView()
    private var lastVersion = 0

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        // Above app windows, below menus and popovers of the app underneath.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func apply(_ snapshot: OverlaySnapshot) {
        guard snapshot.version > lastVersion else { return }
        lastVersion = snapshot.version
        let here = ScreenGeometry.quartzRect(fromAppKit: frame).origin
        host.apply(snapshot, offset: CGVector(dx: snapshot.origin.x - here.x, dy: snapshot.origin.y - here.y))
    }

    func move(to frame: NSRect) {
        setFrame(frame, display: false)
    }

    /// Moves the panel while keeping its blocks fixed on screen, so translations stay glued to the content
    /// under a dragged lens until the pipeline catches up.
    func slide(to newFrame: NSRect) {
        let dx = newFrame.minX - frame.minX, dyDown = -(newFrame.maxY - frame.maxY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.offsetBlocks(dx: -dx, dy: -dyDown)
        setFrame(newFrame, display: false)
        CATransaction.commit()
    }

    /// Fades the translations out (show original) or back in.
    func setTranslationsVisible(_ visible: Bool, animated: Bool = true) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.18 : 0
            animator().alphaValue = visible ? 1 : 0
        }
    }

    /// A brief outline so the user sees where a new region landed.
    func flashOutline() {
        host.flashOutline()
    }
}

private final class OverlayHostView: NSView {
    private var layersByID: [UUID: CALayer] = [:]
    private let outline = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.isGeometryFlipped = true // block frames are top-left based
        layerContentsRedrawPolicy = .never
        outline.fillColor = nil
        outline.strokeColor = NSColor.controlAccentColor.cgColor
        outline.lineWidth = 2
        outline.opacity = 0
        layer?.addSublayer(outline)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        layer?.contentsScale = s
        layersByID.values.forEach { $0.contentsScale = s }
    }

    func apply(_ snapshot: OverlaySnapshot, offset: CGVector) {
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var seen = Set<UUID>()
        for var block in snapshot.blocks {
            block.frame = block.frame.offsetBy(dx: offset.dx, dy: offset.dy)
            seen.insert(block.id)
            if let l = layersByID[block.id] {
                if snapshot.animated, (l.contents as AnyObject?) !== block.image {
                    let fade = CATransition()
                    fade.type = .fade
                    fade.duration = 0.22
                    l.add(fade, forKey: "contents")
                }
                l.frame = block.frame
                l.contents = block.image
            } else {
                let l = CALayer()
                l.contentsScale = scale
                l.contentsGravity = .resize
                l.magnificationFilter = .linear
                l.frame = block.frame
                l.contents = block.image
                layer?.insertSublayer(l, below: outline)
                layersByID[block.id] = l
                if snapshot.animated {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0
                    fade.toValue = 1
                    fade.duration = 0.22
                    l.add(fade, forKey: "appear")
                }
            }
        }
        for (id, l) in layersByID where !seen.contains(id) {
            layersByID[id] = nil
            if snapshot.animated {
                CATransaction.begin()
                CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.duration = 0.18
                l.opacity = 0
                l.add(fade, forKey: "disappear")
                CATransaction.commit()
            } else {
                l.removeFromSuperlayer()
            }
        }
        CATransaction.commit()
    }

    func offsetBlocks(dx: CGFloat, dy: CGFloat) {
        for l in layersByID.values { l.position = CGPoint(x: l.position.x + dx, y: l.position.y + dy) }
    }

    func flashOutline() {
        outline.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 6, cornerHeight: 6, transform: nil)
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0, 0.9, 0.9, 0]
        a.keyTimes = [0, 0.15, 0.6, 1]
        a.duration = 1.4
        outline.add(a, forKey: "flash")
    }
}
