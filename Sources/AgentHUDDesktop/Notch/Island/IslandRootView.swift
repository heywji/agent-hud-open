import SwiftUI
import AgentHUDCore

/// A single silhouette: the closed notch, or the hovered usage panel growing out of it — or, on a logo queue, out of
/// the screen edge the queue is parked on.
struct IslandRootView: View {
    let store: UsageStore?
    let isOpen: Bool
    let collapsedSize: CGSize
    let collapsedTopRadius: CGFloat
    let collapsedBottomRadius: CGFloat
    let lightBorder: Bool
    var onOpenSettings: () -> Void = {}
    var presentationSize: CGSize? = nil
    /// The actual card inside a canvas that can also hold a longer logo strip. Coordinates are local,
    /// top-left based; the card and its upright content share this exact frame with the shadow.
    var presentationFrame: CGRect? = nil
    var animatesGeometry = true
    var onContentHeight: (CGFloat) -> Void = { _ in }
    var onGeometryCompletion: () -> Void = {}
    /// Set on a screen in logo mode: the marks ride on top of the silhouette, collapsed or open, so hovering
    /// never makes the agents disappear.
    var logoQueue: LogoQueueConfig? = nil
    /// Set on a screen whose HUD is a logo queue. Collapsed, such a HUD has no silhouette: it is the marks
    /// over whatever is behind them. Kept apart from `logoQueue`, which only says whether marks are drawn —
    /// hiding them must not bring the black shape back.
    var hidesSilhouette = false
    /// Where the queue's strip sits inside the window, in points down from its top edge, and how tall it is.
    /// The window's own top edge moves between the collapsed and the expanded frame; the marks must not.
    var logoQueueInset: CGFloat = 0
    var logoQueueHeight: CGFloat = 0
    var edge: HUDEdge = .top
    /// The queue's exact rect in the window, using SwiftUI's top-left coordinates. It stays anchored while
    /// the panel grows inward, including when clamping the panel near a screen corner moves its centre.
    var logoQueueFrame: CGRect? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let expandedTopRadius: CGFloat = NotchGeometry.expandedTopRadius
    static let expandedBottomRadius: CGFloat = IslandController.expandedRadius

    static var placeholder: IslandRootView {
        IslandRootView(store: nil, isOpen: false, collapsedSize: CGSize(width: 216, height: 32),
                       collapsedTopRadius: NotchGeometry.collapsedTopRadius, collapsedBottomRadius: 12,
                       lightBorder: false)
    }

    var body: some View {
        GeometryReader { proxy in
            let bounds = proxy.size
            let size = isOpen ? (presentationFrame?.size ?? presentationSize ?? bounds) : collapsedSize
            let shape = IslandShape(
                topRadius: isOpen ? Self.expandedTopRadius : collapsedTopRadius,
                bottomRadius: isOpen ? Self.expandedBottomRadius : collapsedBottomRadius,
                edge: edge
            )
            // A collapsed logo queue is the marks alone: no silhouette behind them, so they read as agents
            // sitting on the desktop rather than as a bar. The silhouette comes back the moment the panel
            // opens — but never because the marks were hidden.
            let bare = hidesSilhouette && !isOpen
            let surface = ZStack(alignment: surfaceAlignment) {
                // Keep one shape alive through collapse so it can shrink before becoming transparent.
                shape.fill(.black)
                    .overlay {
                        if lightBorder { shape.stroke(.white.opacity(0.18), lineWidth: 1) }
                    }
                    .frame(width: size.width, height: size.height)
                    .opacity(bare ? 0 : 1)
                content
                    .mask(alignment: surfaceAlignment) { shape.frame(width: size.width, height: size.height) }
            }
            ZStack(alignment: .topLeading) {
                if let presentationFrame {
                    // The native canvas changes immediately. Only the card's size and its position
                    // along the parked edge interpolate; the contact edge stays on that canvas.
                    let offset = (hidesSilhouette ? edge : .top).isHorizontal
                        ? CGSize(width: presentationFrame.midX - bounds.width / 2, height: 0)
                        : CGSize(width: 0, height: presentationFrame.midY - bounds.height / 2)
                    surface
                        .frame(width: presentationFrame.width, height: presentationFrame.height,
                               alignment: surfaceAlignment)
                        .offset(offset)
                        .animation(geometryAnimation, value: presentationFrame)
                        .transaction(value: presentationFrame) { transaction in
                            if animatesGeometry {
                                transaction.addAnimationCompletion(criteria: .removed, onGeometryCompletion)
                            }
                        }
                        .frame(width: bounds.width, height: bounds.height, alignment: surfaceAlignment)
                } else {
                    surface
                        .animation(geometryAnimation, value: size)
                        .frame(width: bounds.width, height: bounds.height, alignment: surfaceAlignment)
                }
                if let logoQueue {
                    if let logoQueueFrame {
                        LogoQueueView(config: logoQueue, light: lightBorder)
                            .frame(width: logoQueueFrame.width, height: logoQueueFrame.height)
                            .position(x: logoQueueFrame.midX, y: logoQueueFrame.midY)
                            .frame(width: bounds.width, height: bounds.height)
                            .transaction { $0.animation = nil }
                    } else {
                        LogoQueueView(config: logoQueue, light: lightBorder)
                            .frame(width: size.width, height: logoQueueHeight)
                            .padding(.top, logoQueueInset)
                            .frame(width: bounds.width, height: bounds.height, alignment: surfaceAlignment)
                            .transaction { $0.animation = nil }
                    }
                }
            }
            .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .id(store?.settings.settings.language ?? .system)
    }

    @ViewBuilder
    var content: some View {
        if isOpen, let store {
            HoverPanelView(store: store, onOpenSettings: onOpenSettings,
                           height: panelPresentationHeight,
                           insets: hidesSilhouette ? Self.dockInsets(edge: edge, collapsedSize: collapsedSize) : HoverPanelView.notchInsets)
                .frame(width: IslandController.expandedWidth, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .onPreferenceChange(PanelHeightKey.self, perform: onContentHeight)
                .transition(detailTransition)
        }
    }

    /// Only the strip's thickness is clearance. A long vertical queue must not turn into top padding.
    static func dockInsets(edge: HUDEdge, collapsedSize: CGSize) -> EdgeInsets {
        let strip = edge.isHorizontal ? collapsedSize.height : collapsedSize.width
        var insets = EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)
        switch edge {
        case .top: insets.top = strip + 12
        case .bottom: insets.bottom = strip + 12
        case .left: insets.leading = strip + 12
        case .right: insets.trailing = strip + 12
        }
        return insets
    }

    /// Side flares live above and below the content core. The fixed-height usage panel stays upright,
    /// centred between those shoulders, and the reported natural height still describes only the core.
    private var panelPresentationHeight: CGFloat? {
        guard let height = presentationFrame?.height ?? presentationSize?.height else { return nil }
        return hidesSilhouette && !edge.isHorizontal ? max(0, height - 2 * Self.expandedTopRadius) : height
    }

    private var surfaceAlignment: Alignment {
        IslandAnimation.attachmentAlignment(for: hidesSilhouette ? edge : .top)
    }

    private var geometryAnimation: Animation? {
        animatesGeometry && !reduceMotion ? IslandAnimation.curve : nil
    }

    private var detailTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let offset = IslandAnimation.entryOffset(for: hidesSilhouette ? edge : .top)
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(offset)).animation(.easeOut(duration: 0.22).delay(0.12)),
            removal: .opacity.animation(.easeOut(duration: 0.1))
        )
    }
}
