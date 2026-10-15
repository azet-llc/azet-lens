import AppKit
import QuartzCore

/// Transparent, click-through panel floating over a region. Shows one layer per translated block.
///
/// The panel is larger than the lens by `spill` on every side, so a block that is mostly inside the lens is drawn
/// whole instead of being cut at the lens edge; blocks mostly outside it are hidden and the original shows.
final class OverlayPanel: NSPanel {
    static let spill: CGFloat = 160
    private let host = OverlayHostView()
    private var lastVersion = 0

    /// `frame` is the lens, AppKit coordinates.
    init(frame: NSRect) {
        super.init(contentRect: frame.insetBy(dx: -Self.spill, dy: -Self.spill), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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

    func move(to lens: NSRect) {
        setFrame(lens.insetBy(dx: -Self.spill, dy: -Self.spill), display: false)
        host.updateVisibility(animated: false)
    }

    /// Moves the panel while keeping its blocks fixed on screen, so translations stay glued to the content
    /// under a dragged lens until the pipeline catches up.
    func slide(to lens: NSRect) {
        let newFrame = lens.insetBy(dx: -Self.spill, dy: -Self.spill)
        let dx = newFrame.minX - frame.minX, dyDown = -(newFrame.maxY - frame.maxY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.offsetBlocks(dx: -dx, dy: -dyDown)
        setFrame(newFrame, display: false)
        CATransaction.commit()
        host.updateVisibility(animated: true)
    }

    /// Fades the translations out (show original) or back in.
    func setTranslationsVisible(_ visible: Bool, animated: Bool = true) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.18 : 0
            animator().alphaValue = visible ? 1 : 0
        }
    }
}

private final class OverlayHostView: NSView {
    private var layersByID: [UUID: CALayer] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.isGeometryFlipped = true // block frames are top-left based
        layerContentsRedrawPolicy = .never
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
                layer?.addSublayer(l)
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
        updateVisibility(animated: snapshot.animated)
    }

    /// Shows a block when at least half of it, or half of the lens, is covered by it; hides the rest.
    func updateVisibility(animated: Bool) {
        let lens = bounds.insetBy(dx: OverlayPanel.spill, dy: OverlayPanel.spill)
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.15 : 0)
        CATransaction.setDisableActions(!animated)
        for l in layersByID.values {
            let inter = l.frame.intersection(lens)
            let area = inter.isNull ? 0 : inter.width * inter.height
            let show = area >= 0.5 * l.frame.width * l.frame.height || area >= 0.5 * lens.width * lens.height
            let opacity: Float = show ? 1 : 0
            if l.opacity != opacity { l.opacity = opacity }
        }
        CATransaction.commit()
    }

    func offsetBlocks(dx: CGFloat, dy: CGFloat) {
        for l in layersByID.values { l.position = CGPoint(x: l.position.x + dx, y: l.position.y + dy) }
    }
}
