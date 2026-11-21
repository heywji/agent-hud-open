import AppKit
import SwiftUI
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class DockLayoutTests: XCTestCase {
    @MainActor
    func testEveryDockEdgeKeepsTheContactFlaresAndInsetInwardSides() {
        for edge in HUDEdge.allCases {
            let rect = CGRect(x: 37, y: 53, width: edge.isHorizontal ? 240 : 120,
                              height: edge.isHorizontal ? 120 : 240)
            let path = IslandShape(topRadius: 16, bottomRadius: 26, edge: edge).path(in: rect)
            XCTAssertEqual(path.boundingRect, rect, "\(edge) must touch the full contact edge and reach into the screen")

            func point(along: CGFloat, inward: CGFloat) -> CGPoint {
                switch edge {
                case .top: return CGPoint(x: rect.minX + along, y: rect.minY + inward)
                case .bottom: return CGPoint(x: rect.minX + along, y: rect.maxY - inward)
                case .left: return CGPoint(x: rect.minX + inward, y: rect.minY + along)
                case .right: return CGPoint(x: rect.maxX - inward, y: rect.minY + along)
                }
            }
            for along in [CGFloat(4), 236] {
                XCTAssertTrue(path.contains(point(along: along, inward: 0.1)),
                              "\(edge) must flare outward near both contact corners")
                XCTAssertFalse(path.contains(point(along: along, inward: 4)),
                               "\(edge) contact corners must curve inward from the edge")
            }
            XCTAssertFalse(path.contains(point(along: 12, inward: 30)),
                           "The side beyond a contact flare must sit 16pt inside the window")
            XCTAssertTrue(path.contains(point(along: 17, inward: 30)))
            XCTAssertFalse(path.contains(point(along: 17, inward: 119)), "The inward corner must remain convex")
            XCTAssertTrue(path.contains(point(along: 43, inward: 119)))
        }
    }

    @MainActor
    func testVerticalQueueLengthDoesNotBecomePanelTopClearance() throws {
        _ = NSApplication.shared
        let domain = "app.agenthud.tests.dock-layout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        settings.update {
            $0.showIslandQuota = false
            $0.showIslandTokens = false
            $0.showIslandSessions = false
        }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        for edge in [HUDEdge.left, .right] {
            var root = IslandRootView(store: store, isOpen: true, collapsedSize: CGSize(width: 32, height: 80),
                                      collapsedTopRadius: 8, collapsedBottomRadius: 10,
                                      lightBorder: false)
            root.hidesSilhouette = true
            root.edge = edge
            let controller = IslandWindowController(
                frame: CGRect(x: -20000, y: -20000, width: 540, height: 400), rootView: root)
            let shortHeight = controller.contentHeight(for: root)
            root = IslandRootView(store: store, isOpen: true, collapsedSize: CGSize(width: 32, height: 400),
                                  collapsedTopRadius: 8, collapsedBottomRadius: 10,
                                  lightBorder: false)
            root.hidesSilhouette = true
            root.edge = edge
            XCTAssertEqual(controller.contentHeight(for: root), shortHeight, accuracy: 1,
                           "Adding logos down a side must not push the content down or make the card taller")
            XCTAssertLessThan(shortHeight, 150, "A dock with no content should remain a compact footer")
        }
    }

    @MainActor
    func testOpenDockKeepsLogoQueueAtItsExplicitWindowRectOnEveryEdge() async throws {
        _ = NSApplication.shared
        let size = CGSize(width: 540, height: 400)
        let cases: [(HUDEdge, CGRect)] = [
            (.top, CGRect(x: 58, y: 0, width: 200, height: 32)),
            (.bottom, CGRect(x: 58, y: 368, width: 200, height: 32)),
            (.left, CGRect(x: 0, y: 58, width: 32, height: 200)),
            (.right, CGRect(x: 508, y: 58, width: 32, height: 200))
        ]
        for (edge, rect) in cases {
            let placement = ScreenPlacement(mode: .logos, edge: edge)
            var root = IslandRootView(store: nil, isOpen: true, collapsedSize: rect.size,
                                      collapsedTopRadius: 8, collapsedBottomRadius: 10,
                                      lightBorder: false)
            root.hidesSilhouette = true
            root.edge = edge
            root.logoQueue = LogoQueueConfig(items: [LogoQueueItem(vendor: "Claude")],
                                             placement: placement)
            root.logoQueueFrame = rect
            root.presentationSize = size
            root.animatesGeometry = false
            let controller = IslandWindowController(
                frame: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), rootView: root)
            let hosting = try XCTUnwrap(controller.panel.contentView)
            controller.show()
            defer { controller.panel.orderOut(nil) }
            let deadline = Date().addingTimeInterval(3)
            while queue(in: hosting) == nil, Date() < deadline {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            hosting.layoutSubtreeIfNeeded()
            let queue = try XCTUnwrap(queue(in: hosting))
            let actual = queue.convert(queue.bounds, to: hosting)
            let expectedY = hosting.isFlipped ? rect.minY : size.height - rect.maxY
            XCTAssertEqual(actual.minX, rect.minX, accuracy: 1, "\(edge) must keep its along-edge offset")
            XCTAssertEqual(actual.minY, expectedY, accuracy: 1, "\(edge) must remain parked at the window edge")
            XCTAssertEqual(actual.width, rect.width, accuracy: 1)
            XCTAssertEqual(actual.height, rect.height, accuracy: 1)
        }
    }

    @MainActor
    func testShortSideCardUsesItsExplicitFrameInsideALongQueueCanvas() async throws {
        _ = NSApplication.shared
        let domain = "app.agenthud.tests.dock-canvas.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        settings.update {
            $0.showIslandQuota = false
            $0.showIslandTokens = false
            $0.showIslandSessions = false
        }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        let canvas = CGSize(width: 540, height: 400)
        let card = CGRect(x: 0, y: 200, width: 540, height: 120)
        let strip = CGRect(x: 508, y: 0, width: 32, height: 400)
        var root = IslandRootView(store: store, isOpen: true, collapsedSize: strip.size,
                                  collapsedTopRadius: 8, collapsedBottomRadius: 10,
                                  lightBorder: false)
        root.hidesSilhouette = true
        root.edge = .right
        root.presentationSize = canvas
        root.presentationFrame = card
        root.logoQueueFrame = strip
        root.logoQueue = LogoQueueConfig(items: (0..<12).map { _ in
            LogoQueueItem(vendor: "Claude")
        }, placement: ScreenPlacement(mode: .logos, edge: .right, logoSize: 24))
        root.animatesGeometry = false
        let controller = IslandWindowController(
            frame: CGRect(x: -20000, y: -20000, width: canvas.width, height: canvas.height), rootView: root)
        let hosting = try XCTUnwrap(controller.panel.contentView)
        controller.show()
        defer { controller.panel.orderOut(nil) }
        let deadline = Date().addingTimeInterval(3)
        while queue(in: hosting) == nil, Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        hosting.layoutSubtreeIfNeeded()
        let queue = try XCTUnwrap(queue(in: hosting))
        let queueRect = topLeftRect(queue.convert(queue.bounds, to: hosting), in: hosting)
        XCTAssertEqual(queueRect, strip, "The independently anchored logos must retain the full 400pt canvas")

        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        // The footer's 28 pt controls end at the card's own bottom inset, inside the short card at its explicit y=200:
        // the card's height places them, not the whole queue canvas.
        let footer = CGRect(x: 0, y: card.maxY - IslandRootView.expandedTopRadius - 14 - 28, width: strip.minX, height: 28)
        XCTAssertTrue(card.contains(footer))
        XCTAssertGreaterThan(brightest(in: footer, of: bitmap, canvas: canvas), 0.25,
                             "The footer must be drawn at the bottom of the short card")
        let centreX = bitmap.pixelsWide / 2
        let occupied = (0..<bitmap.pixelsHigh).filter { (bitmap.colorAt(x: centreX, y: $0)?.alphaComponent ?? 0) > 0.9 }
        let scale = canvas.height / CGFloat(bitmap.pixelsHigh)
        XCTAssertEqual(CGFloat(try XCTUnwrap(occupied.first)) * scale,
                       card.minY + IslandRootView.expandedTopRadius, accuracy: 1,
                       "The black card must begin at its own shoulder, rather than being centred in the canvas")
        XCTAssertEqual(CGFloat(try XCTUnwrap(occupied.last)) * scale,
                       card.maxY - IslandRootView.expandedTopRadius, accuracy: 1)
        let lastMark = try XCTUnwrap(queue.layer?.sublayers?.last)
        let lastCentre = topLeftRect(queue.convert(lastMark.frame, to: hosting), in: hosting).midY
        XCTAssertGreaterThan(lastCentre, card.maxY, "The last logo deliberately sits below the card")
        let pixelX = Int(strip.midX * CGFloat(bitmap.pixelsWide) / canvas.width)
        let pixelY = Int(lastCentre / scale)
        XCTAssertGreaterThan(bitmap.colorAt(x: pixelX, y: pixelY)?.alphaComponent ?? 0, 0.9,
                             "A logo outside the card must remain visible instead of being clipped to its mask")
    }

    @MainActor
    private func topLeftRect(_ rect: CGRect, in hosting: NSView) -> CGRect {
        hosting.isFlipped ? rect : CGRect(x: rect.minX, y: hosting.bounds.height - rect.maxY,
                                         width: rect.width, height: rect.height)
    }

    /// The brightest opaque pixel in `rect`, as the mean of its components: the panel's controls are drawn in its
    /// secondary colour over a black card.
    private func brightest(in rect: CGRect, of bitmap: NSBitmapImageRep, canvas: CGSize) -> CGFloat {
        let sx = CGFloat(bitmap.pixelsWide) / canvas.width, sy = CGFloat(bitmap.pixelsHigh) / canvas.height
        var brightest: CGFloat = 0
        for y in Int(rect.minY * sy)..<Int(rect.maxY * sy) where y >= 0 && y < bitmap.pixelsHigh {
            for x in Int(rect.minX * sx)..<Int(rect.maxX * sx) where x >= 0 && x < bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                brightest = max(brightest, (color.redComponent + color.greenComponent + color.blueComponent) / 3)
            }
        }
        return brightest
    }

    @MainActor
    private func queue(in view: NSView) -> LogoQueueLayerView? {
        if let queue = view as? LogoQueueLayerView { return queue }
        return view.subviews.lazy.compactMap { self.queue(in: $0) }.first
    }
}
