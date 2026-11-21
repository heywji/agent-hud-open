import SwiftUI
import AgentHUDCore

/// One mark in the queue. The queue shows one mark per vendor, not per agent: two Claude windows are
/// one Claude.
struct LogoQueueItem: Identifiable, Equatable {
    let vendor: String
    var id: String { vendor }

    /// Collapses agents onto the mark they are drawn with, keeping the order they were watched in. Two
    /// Claude windows are one Claude; so are Codex and ChatGPT, which share OpenAI's artwork — a second
    /// identical mark would take a place in the row and tell a glance nothing.
    @MainActor
    static func queue(rows: [(vendor: String, isWorking: Bool)]) -> [LogoQueueItem] {
        var order: [String] = []
        var vendors: [String: String] = [:]
        for row in rows {
            let key = AgentArtwork.markKey(row.vendor)
            if vendors[key] == nil {
                order.append(key)
                vendors[key] = row.vendor
            }
        }
        return order.map { LogoQueueItem(vendor: vendors[$0] ?? $0) }
    }
}

/// A queue resolved for one screen: what to draw, and how big.
struct LogoQueueConfig: Equatable {
    var items: [LogoQueueItem]
    var edge: HUDEdge
    /// Side of one mark, in points.
    var logo: CGFloat
    var edgeDistance: CGFloat
    var gap: CGFloat

    init(items: [LogoQueueItem], placement: ScreenPlacement) {
        self.items = items
        edge = placement.edge
        logo = placement.logoSize
        edgeDistance = placement.logoEdgeDistance
        gap = logo * placement.gapScale
    }

    /// The strip touches the screen edge; centring the marks within it keeps their edge at the requested distance.
    var stripThickness: CGFloat { logo + edgeDistance * 2 }

    /// The marks' run, with their screen-edge distance perpendicular to the run.
    var size: CGSize {
        guard !items.isEmpty else { return .zero }
        let run = logo * CGFloat(items.count) + gap * CGFloat(items.count - 1)
        return edge.isHorizontal ? CGSize(width: run, height: stripThickness) : CGSize(width: stripThickness, height: run)
    }
}

/// The collapsed HUD on a screen in logo mode: every watched agent's own mark, at a fixed place.
struct LogoQueueView: NSViewRepresentable {
    let config: LogoQueueConfig
    let light: Bool

    @Environment(\.displayScale) private var displayScale

    func makeNSView(context: Context) -> LogoQueueLayerView { LogoQueueLayerView() }

    func updateNSView(_ view: LogoQueueLayerView, context: Context) {
        view.apply(config: config, light: light, scale: displayScale)
    }
}

/// Lays stationary marks out along the edge.
final class LogoQueueLayerView: NSView {
    private(set) var marks: [CALayer] = []
    /// How far the baked outline overflows a mark, in points, so the layout leaves room for exactly that.
    private var bleed: CGFloat = 1
    /// Alpha bounds in each baked bitmap, including its outline, normalized with y running down.
    private var visibleBounds: [CGRect] = []
    private var applied: (config: LogoQueueConfig, light: Bool, scale: CGFloat)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard let applied else { return }
        position(config: applied.config)
    }

    /// The marks are laid out against the view's own bounds, so a size change has to reach them even when
    /// AppKit does not consider the bounds themselves changed.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let applied { position(config: applied.config) }
    }

    func apply(config: LogoQueueConfig, light: Bool, scale: CGFloat) {
        if let applied, applied.config == config, applied.light == light, applied.scale == scale { return }
        let rebuild = applied?.config.items.map(\.id) != config.items.map(\.id)
            || applied?.light != light || applied?.scale != scale
            || applied?.config.logo != config.logo
        applied = (config, light, scale)
        if rebuild { build(config: config, light: light, scale: scale) }
        position(config: config)
    }

    private func build(config: LogoQueueConfig, light: Bool, scale: CGFloat) {
        marks.forEach { $0.removeFromSuperlayer() }
        let side = Int((config.logo * scale).rounded())
        // One device pixel at any size: a hairline reads as the mark's own edge, anything thicker as a
        // border drawn around it.
        let outline = 1
        bleed = CGFloat(outline) / max(1, scale)
        // The queue sits on the wallpaper: the dark artwork variant is the one that reads there.
        visibleBounds = []
        marks = config.items.map { item in
            let mark = CALayer()
            mark.contentsScale = scale
            mark.contentsGravity = .resizeAspect
            let key = LogoImages.Key(vendor: item.vendor, side: side, outline: outline, light: false)
            mark.contents = LogoImages.image(key)
            visibleBounds.append(LogoImages.visibleBounds(key))
            layer?.addSublayer(mark)
            return mark
        }
    }

    private func position(config: LogoQueueConfig) {
        // The baked outline overflows the mark on every edge, so each layer is grown by exactly that and the
        // extra is centred away; the spacing the user set still applies to the marks themselves.
        let step = config.logo + config.gap
        // The view is given the window's width, which is wider than the run; the queue sits in the middle
        // of it, as the notch does.
        let run = config.edge.isHorizontal ? config.size.width : config.size.height
        let lead = max(0, ((config.edge.isHorizontal ? bounds.width : bounds.height) - run) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, mark) in marks.enumerated() {
            let along = lead + CGFloat(index) * step
            var origin = config.edge.isHorizontal
                ? CGPoint(x: along, y: (bounds.height - config.logo) / 2)
                : CGPoint(x: (bounds.width - config.logo) / 2, y: along)
            if index < visibleBounds.count, !visibleBounds[index].isEmpty {
                let alpha = visibleBounds[index], side = config.logo + bleed * 2
                let visible = CGRect(x: origin.x - bleed + alpha.minX * side,
                                     y: origin.y - bleed + alpha.minY * side,
                                     width: alpha.width * side, height: alpha.height * side)
                // Assets carry different transparent padding. Shift only toward/away from the parked edge;
                // the configured logo size and along-edge spacing continue to use the original artwork box.
                switch config.edge {
                case .top: origin.y += config.edgeDistance - visible.minY
                case .bottom: origin.y += bounds.height - config.edgeDistance - visible.maxY
                case .left: origin.x += config.edgeDistance - visible.minX
                case .right: origin.x += bounds.width - config.edgeDistance - visible.maxX
                }
            }
            mark.frame = CGRect(x: origin.x - bleed, y: origin.y - bleed,
                                width: config.logo + bleed * 2, height: config.logo + bleed * 2)
        }
        CATransaction.commit()
    }
}
