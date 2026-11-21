import Foundation

/// How one screen presents the HUD.
public enum HUDMode: String, Codable, Sendable, CaseIterable {
    /// The island: the notch itself, or a bar standing in for one on displays without.
    case notch
    /// A queue of the agents' own logos, parked on a screen edge.
    case logos
    /// No HUD on this screen at all: no island, no queue, no hover panel.
    case off

    /// Parked on a screen edge and opening inward from it, rather than standing at the notch.
    public var isDocked: Bool { self == .logos }
}

/// The screen edge a HUD is parked on. It runs along that edge and opens inward.
public enum HUDEdge: String, Codable, Sendable, CaseIterable {
    case top, right, bottom, left

    public var isHorizontal: Bool { self == .top || self == .bottom }

    /// Unit vector pointing into the screen from this edge.
    public var inward: (x: Double, y: Double) {
        switch self {
        case .top: return (0, -1)
        case .bottom: return (0, 1)
        case .left: return (1, 0)
        case .right: return (-1, 0)
        }
    }
}

/// One screen's HUD. Everything here is per screen: two displays can run different modes, sit on
/// different edges and size their logos differently.
public struct ScreenPlacement: Hashable, Codable, Sendable {
    /// Side of one mark in points, independent of the display's menu bar height.
    public static let logoSizeRange: ClosedRange<Double> = 12...36
    /// Distance from the visible logo, including its outline, to its parked screen edge, in points.
    public static let logoEdgeDistanceRange: ClosedRange<Double> = 0...20
    /// Gap between logos, as a share of the logo's height. A gap wider than about half a mark reads as
    /// separate marks rather than one queue.
    public static let gapScaleRange: ClosedRange<Double> = 0.1...0.6
    public var mode: HUDMode
    public var edge: HUDEdge
    /// The queue's centre along its edge, as a fraction of that edge's length, so it survives a
    /// resolution change.
    public var offset: Double
    public var logoSize: Double
    public var logoEdgeDistance: Double
    public var gapScale: Double
    /// Draw the marks. Turning them off keeps the queue's place and width; only the logos stop being drawn.
    public var showsLogos: Bool

    public init(
        mode: HUDMode = .logos,
        edge: HUDEdge = .top,
        offset: Double = 0.5,
        logoSize: Double = 20,
        logoEdgeDistance: Double = 2,
        gapScale: Double = 0.4,
        showsLogos: Bool = true
    ) {
        self.mode = mode
        self.edge = edge
        self.offset = Self.clamp(offset, to: 0...1)
        self.logoSize = Self.clamp(logoSize, to: Self.logoSizeRange)
        self.logoEdgeDistance = Self.clamp(logoEdgeDistance, to: Self.logoEdgeDistanceRange)
        self.gapScale = Self.clamp(gapScale, to: Self.gapScaleRange)
        self.showsLogos = showsLogos
    }

    /// A display's starting point: a notched screen keeps its island, anything else shows the queue.
    public static func `default`(hasNotch: Bool) -> ScreenPlacement {
        ScreenPlacement(mode: hasNotch ? .notch : .logos)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value.isFinite ? value : range.lowerBound))
    }

    private enum CodingKeys: String, CodingKey {
        case mode, edge, offset, logoSize, logoEdgeDistance, gapScale, showsLogos
    }

    /// A mode this build does not have, such as a fuller build's Simple panel, reads as the logo queue that
    /// stands closest to it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScreenPlacement()
        self.init(
            mode: (try? c.decodeIfPresent(HUDMode.self, forKey: .mode)) ?? d.mode,
            edge: (try? c.decodeIfPresent(HUDEdge.self, forKey: .edge)) ?? d.edge,
            offset: try c.decodeIfPresent(Double.self, forKey: .offset) ?? d.offset,
            logoSize: try c.decodeIfPresent(Double.self, forKey: .logoSize) ?? d.logoSize,
            logoEdgeDistance: try c.decodeIfPresent(Double.self, forKey: .logoEdgeDistance) ?? d.logoEdgeDistance,
            gapScale: try c.decodeIfPresent(Double.self, forKey: .gapScale) ?? d.gapScale,
            showsLogos: try c.decodeIfPresent(Bool.self, forKey: .showsLogos) ?? d.showsLogos
        )
    }
}
