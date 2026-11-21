import AppKit
import CoreImage
import QuartzCore
import AgentHUDCore

/// A pre-rendered, blurred shadow bitmap.
struct ShadowImage: Sendable {
    let image: CGImage
    /// Extra points on every side so the blur is not clipped by the bitmap edge.
    let padding: CGFloat
    /// Bitmap size in points, padding included.
    let size: CGSize
}

/// The blur context every rasteriser shares. A `CIContext` renders immutable images, so any thread may draw
/// through the same one; it travels in a box because not every SDK declares the class `Sendable`.
private final class BlurContext: @unchecked Sendable {
    static let shared = BlurContext()
    let ci = CIContext(options: [.useSoftwareRenderer: false])
}

/// Click-through window behind the island that holds its drop shadow (`0 8px 30px rgba(0,0,0,.35)`).
/// The canvas spans the display height and stays fixed during expansion; only the shadow layer inside moves.
@MainActor
final class ShadowWindowController {
    let panel: OverlayPanel
    private let host = NSView()
    /// Draw in the top-edge coordinate space, then turn the canvas toward the chosen edge, so one bitmap serves
    /// every edge a queue can be parked on.
    private let canvas = CALayer()
    let shadowLayer = CALayer()
    private var shadowKey: ShadowKey?
    private var shadowPadding: CGFloat = 0

    static let panelWidth: CGFloat = 1000
    nonisolated static let blur: CGFloat = 15

    fileprivate struct ShadowKey: Hashable, Sendable {
        let size: CGSize
        let radius: CGFloat
        let scale: CGFloat
    }

    /// The bitmap for one pending surface. The hover owner retains it until the panel opens or the pointer leaves.
    struct PreparedImages: Sendable {
        fileprivate let shadowKey: ShadowKey
        let shadow: ShadowImage?
    }

    /// Screen queries happen before this value is handed to the raster worker.
    struct PreparationInputs: Sendable {
        fileprivate let shadowKey: ShadowKey
        fileprivate let rendersShadow: Bool
    }

    init(geometry: NotchGeometry) {
        panel = OverlayPanel(frame: Self.panelFrame(for: geometry), level: .statusBar, acceptsMouse: false)
        panel.setAccessibilityElement(false)
        panel.setAccessibilityHidden(true)
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        panel.contentView = host
        host.layer?.addSublayer(canvas)
        shadowLayer.contentsGravity = .resize
        shadowLayer.contentsScale = geometry.backingScale
        shadowLayer.anchorPoint = .zero
        shadowLayer.opacity = 0
        canvas.addSublayer(shadowLayer)
    }

    static func panelFrame(for geometry: NotchGeometry) -> CGRect {
        // A logo queue's panel spans the screen, because the panel it opens is wider than the marks.
        guard !geometry.mode.isDocked else { return geometry.screenFrame }
        return CGRect(
            x: geometry.centerX - panelWidth / 2,
            y: geometry.screenFrame.minY,
            width: panelWidth,
            height: geometry.screenFrame.height
        )
    }

    /// The island expressed with its parked edge at the top. For vertical queues, increasing x follows
    /// the marks from top to bottom.
    nonisolated static func canonicalIslandFrame(_ island: CGRect, panel: CGRect, edge: HUDEdge) -> CGRect {
        let local = island.offsetBy(dx: -panel.minX, dy: -panel.minY)
        switch edge {
        case .top: return local
        case .bottom:
            return CGRect(x: local.minX, y: panel.height - local.maxY, width: local.width, height: local.height)
        case .left:
            return CGRect(x: panel.height - local.maxY, y: panel.width - local.maxX,
                          width: local.height, height: local.width)
        case .right:
            return CGRect(x: panel.height - local.maxY, y: local.minX,
                          width: local.height, height: local.width)
        }
    }

    private func orientCanvas(in frame: CGRect, edge: HUDEdge) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.bounds = CGRect(origin: .zero, size: edge.isHorizontal
            ? frame.size : CGSize(width: frame.height, height: frame.width))
        canvas.position = CGPoint(x: frame.width / 2, y: frame.height / 2)
        let transform: CGAffineTransform
        switch edge {
        case .top: transform = .identity
        case .bottom: transform = CGAffineTransform(scaleX: 1, y: -1)
        case .left: transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 0, ty: 0)
        case .right: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        }
        canvas.setAffineTransform(transform)
        CATransaction.commit()
    }

    /// What the shadow of `island` needs drawn, taken on the main actor while the hover delay runs.
    /// - casts: whether the island has a shape to cast one; a collapsed logo queue is its marks alone.
    func capturePreparation(geometry: NotchGeometry, island: CGRect, islandRadius: CGFloat, casts: Bool) -> PreparationInputs {
        let local = Self.canonicalIslandFrame(island, panel: Self.panelFrame(for: geometry), edge: geometry.edge)
        return PreparationInputs(shadowKey: ShadowKey(size: local.size, radius: islandRadius, scale: geometry.backingScale),
                                 rendersShadow: casts)
    }

    /// Only immutable Core Graphics values reach this function; no window or AppKit queries occur here.
    nonisolated static func render(_ inputs: PreparationInputs) -> PreparedImages {
        let key = inputs.shadowKey
        let shadow = inputs.rendersShadow
            ? renderShadow(width: key.size.width, height: key.size.height, cornerRadius: key.radius, scale: key.scale)
            : nil
        return PreparedImages(shadowKey: key, shadow: shadow)
    }

    /// A clock or data refresh can change panel inputs without changing the installed bitmap. Reuse it then, so those
    /// refreshes neither draw again nor briefly hide the shadow.
    func installedPreparation(matching inputs: PreparationInputs) -> PreparedImages? {
        guard !inputs.rendersShadow || shadowKey == inputs.shadowKey else { return nil }
        return PreparedImages(shadowKey: inputs.shadowKey, shadow: nil)
    }

    /// - island: the island's frame in screen coordinates.
    /// - casts: whether it has a shape to cast a shadow.
    func update(geometry: NotchGeometry, island: CGRect, islandRadius: CGFloat, casts: Bool, animated: Bool,
                prepared: PreparedImages? = nil, materialsPending: Bool = false) {
        let frame = Self.panelFrame(for: geometry)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        orientCanvas(in: frame, edge: geometry.edge)
        shadowLayer.contentsScale = geometry.backingScale
        if !panel.isVisible { panel.orderFrontRegardless() }

        // Opening and collapse commit their window geometry immediately; the worker supplies a correctly shaped bitmap.
        // A previous surface's shadow must not be stretched over a different panel while that result is pending.
        shadowLayer.isHidden = materialsPending || !casts
        guard casts, !materialsPending else { return }

        let local = Self.canonicalIslandFrame(island, panel: frame, edge: geometry.edge)
        updateShadowImage(island: local, radius: islandRadius, scale: geometry.backingScale, prepared: prepared)
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(IslandAnimation.duration)
            CATransaction.setAnimationTimingFunction(IslandAnimation.mediaCurve)
        } else {
            CATransaction.setDisableActions(true)
        }
        shadowLayer.frame = local.offsetBy(dx: 0, dy: -8).insetBy(dx: -shadowPadding, dy: -shadowPadding)
        shadowLayer.opacity = 1
        CATransaction.commit()
    }

    /// Takes the shadow off screen for good: the display went away with the HUD.
    func close() {
        panel.orderOut(nil)
    }

    private func updateShadowImage(island: CGRect, radius: CGFloat, scale: CGFloat, prepared: PreparedImages?) {
        let key = ShadowKey(size: island.size, radius: radius, scale: scale)
        guard key != shadowKey else { return }
        guard let rendered = (prepared?.shadowKey == key ? prepared?.shadow : nil)
            ?? Self.renderShadow(width: island.width, height: island.height, cornerRadius: radius, scale: scale) else { return }
        shadowKey = key
        shadowPadding = rendered.padding
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.contents = rendered.image
        shadowLayer.contentsCenter = Self.contentsCenter(for: rendered, side: radius, bottom: radius)
        CATransaction.commit()
    }

    /// The bitmap stretches through its nine-slice centre while the island animates, keeping the feather and the
    /// rounded corners at their native size.
    private static func contentsCenter(for image: ShadowImage, side: CGFloat, bottom: CGFloat) -> CGRect {
        let left = min(image.padding + side, (image.size.width - 1) / 2)
        let top = image.padding
        let lower = min(image.padding + bottom, image.size.height - top - 1)
        return CGRect(x: left / image.size.width, y: top / image.size.height,
                      width: (image.size.width - left * 2) / image.size.width,
                      height: (image.size.height - top - lower) / image.size.height)
    }

    // MARK: Rendering

    /// The soft drop shadow of an island `width` × `height` points whose bottom corners round by `cornerRadius`.
    nonisolated static func renderShadow(width: CGFloat, height: CGFloat, cornerRadius: CGFloat, scale: CGFloat) -> ShadowImage? {
        guard !Task.isCancelled else { return nil }
        let padding = ceil(blur * 3)
        let totalWidth = width + padding * 2
        let totalHeight = height + padding * 2
        let pixelWidth = Int((totalWidth * scale).rounded(.up))
        let pixelHeight = Int((totalHeight * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.scaleBy(x: scale, y: scale)
        let rect = CGRect(x: padding, y: padding, width: width, height: height)
        context.addPath(bottomRoundedPath(rect, radius: min(cornerRadius, min(width, height) / 2)))
        context.setFillColor(CGColor(gray: 0, alpha: 0.35))
        context.fillPath()

        guard !Task.isCancelled, let base = context.makeImage() else { return nil }
        let size = CGSize(width: totalWidth, height: totalHeight)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return ShadowImage(image: base, padding: padding, size: size) }
        filter.setValue(CIImage(cgImage: base), forKey: kCIInputImageKey)
        filter.setValue(blur * scale, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage,
              let blurred = BlurContext.shared.ci.createCGImage(output, from: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        else { return ShadowImage(image: base, padding: padding, size: size) }
        return ShadowImage(image: blurred, padding: padding, size: size)
    }

    /// Rectangle whose bottom corners are rounded; the top edge is square (it meets the screen edge).
    nonisolated static func bottomRoundedPath(_ r: CGRect, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let radius = max(0, min(radius, min(r.width, r.height) / 2))
        path.move(to: CGPoint(x: r.minX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + radius))
        path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX - radius, y: r.minY), radius: radius)
        path.addLine(to: CGPoint(x: r.minX + radius, y: r.minY))
        path.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX, y: r.minY + radius), radius: radius)
        path.closeSubpath()
        return path
    }
}
