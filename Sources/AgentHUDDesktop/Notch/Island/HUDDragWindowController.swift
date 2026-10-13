import AppKit
import AgentHUDCore
import QuartzCore

/// A grab surface over the visible HUD. This surface owns the mouse gesture: a press picks the HUD up once
/// it has travelled `HUDDragView.travel` points or been held still for `holdDelay`, and only then do its
/// dashed bounds appear. A click that does neither is left alone.
@MainActor
final class HUDDragWindowController {
    let panel: OverlayPanel
    private let surface = HUDDragView()

    var onPress: (() -> Void)? { didSet { surface.onPress = onPress } }
    var onRelease: (() -> Void)? { didSet { surface.onRelease = onRelease } }
    var onBegin: ((CGPoint) -> Void)? { didSet { surface.onBegin = onBegin } }
    var onDrag: ((CGPoint) -> Void)? { didSet { surface.onDrag = onDrag } }
    var onEnd: (() -> Void)? { didSet { surface.onEnd = onEnd } }
    /// A press let go before it became a pick-up: a plain click on the HUD.
    var onClick: (() -> Void)? { didSet { surface.onClick = onClick } }
    var isDragging: Bool { surface.isDragging }
    var isPressed: Bool { surface.isPressed }
    /// The press has become a pick-up, by travel or by holding.
    var isArmed: Bool { surface.isArmed }
    /// The cursor the surface asks for: the arrow at rest, a closed hand while the HUD is picked up.
    var cursor: NSCursor { surface.cursor }

    init(holdDelay: TimeInterval = 0.3) {
        surface.holdDelay = holdDelay
        panel = OverlayPanel(frame: .zero,
                             level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3),
                             acceptsMouse: true)
        panel.title = "Move Agent HUD"
        panel.contentView = surface
        surface.autoresizingMask = [.width, .height]
        surface.setAccessibilityLabel(L10n.text("拖动 HUD", "Move HUD"))
    }

    /// `outline` is the dashed shape in screen coordinates, for a HUD whose drawn panel is smaller than its grab
    /// surface; without one the dashes follow the surface itself.
    func show(frame: CGRect, outlined: Bool = true, outline: (rect: CGRect, radius: CGFloat)? = nil) {
        panel.setFrame(frame, display: false)
        surface.frame = CGRect(origin: .zero, size: frame.size)
        surface.isOutlined = outlined
        surface.outlineShape = outline.map { ($0.rect.offsetBy(dx: -frame.minX, dy: -frame.minY), $0.radius) }
        surface.updateOutline()
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    /// The dashed path as drawn, in the surface's own coordinates.
    var outlineBounds: CGRect { surface.outlineBounds }
}

@MainActor
private final class HUDDragView: NSView {
    /// How far a press has to travel before it moves the HUD rather than clicking it.
    static let travel: CGFloat = 6

    private let outline = CAShapeLayer()
    private var downAt: CGPoint?
    private var holdTimer: Timer?
    private(set) var isDragging = false
    private(set) var isArmed = false
    var isPressed: Bool { downAt != nil }
    var isOutlined = false
    var holdDelay: TimeInterval = 0.3
    var outlineShape: (rect: CGRect, radius: CGFloat)?
    var outlineBounds: CGRect { outline.path?.boundingBoxOfPath ?? .zero }
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onBegin: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        outline.fillColor = CGColor(gray: 1, alpha: 0.025)
        outline.strokeColor = CGColor(gray: 1, alpha: 0.9)
        outline.lineWidth = 1.25
        outline.lineDashPattern = [4, 3]
        outline.shadowColor = CGColor(gray: 0, alpha: 1)
        outline.shadowOpacity = 0.8
        outline.shadowRadius = 2
        outline.shadowOffset = .zero
        layer?.addSublayer(outline)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateOutline() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.opacity = isOutlined || isArmed ? 1 : 0
        outline.frame = bounds
        let rect = outlineShape?.rect ?? bounds.insetBy(dx: 2, dy: 2)
        let radius = max(0, min(outlineShape?.radius ?? 7, min(rect.width, rect.height) / 2))
        outline.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
    }

    override func layout() { super.layout(); updateOutline() }
    /// The surface moves with the HUD, which rebuilds its cursor rects under the pointer on every step; the
    /// rect has to carry the dragging cursor itself or the arrow comes straight back. At rest the pointer is left
    /// as the app underneath has it: showing a hand there would mean taking that app's keyboard on every hover.
    var cursor: NSCursor { isArmed ? .closedHand : .arrow }
    override func resetCursorRects() { if isArmed { addCursorRect(bounds, cursor: cursor) } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        downAt = window.convertPoint(toScreen: event.locationInWindow)
        onPress?()
        holdTimer?.invalidate()
        let timer = Timer(timeInterval: holdDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.arm() }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    /// The press is now a pick-up: the bounds show, and any further movement moves the HUD.
    private func arm() {
        holdTimer?.invalidate()
        holdTimer = nil
        guard isPressed, !isArmed else { return }
        isArmed = true
        updateOutline()
        // macOS takes a cursor only from the key window, and this panel is never key in an app that is never
        // active. It is key for as long as the HUD is held, without activating the app, and hands the keys back
        // when it is let go.
        (window as? OverlayPanel)?.takeKeyboard()
        window?.invalidateCursorRects(for: self)
        cursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downAt, let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        if !isDragging {
            guard isArmed || hypot(point.x - downAt.x, point.y - downAt.y) >= Self.travel else { return }
            arm()
            isDragging = true
            onBegin?(downAt)
        }
        onDrag?(point)
        cursor.set()
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        let moved = isDragging, clicked = downAt != nil && !isArmed
        if isArmed { (window as? OverlayPanel)?.releaseKeyboard() }
        downAt = nil
        isDragging = false
        isArmed = false
        updateOutline()
        window?.invalidateCursorRects(for: self)
        cursor.set()
        if moved { onEnd?() }
        onRelease?()
        if clicked { onClick?() }
    }
}
