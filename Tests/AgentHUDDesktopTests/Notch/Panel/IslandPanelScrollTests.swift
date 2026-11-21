import AppKit
import SwiftUI
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class IslandPanelScrollTests: XCTestCase {
    @MainActor
    func testLongNotchPanelScrollsWithinItsShortCardOnATallerAnimationCanvas() async throws {
        try await checkPanel(edge: nil)
    }

    @MainActor
    func testLongDockPanelScrollsAboveItsFooterOnEveryEdge() async throws {
        for edge in HUDEdge.allCases {
            try await checkPanel(edge: edge)
        }
    }

    @MainActor
    private func checkPanel(edge: HUDEdge?) async throws {
        _ = NSApplication.shared
        let fixture = try IslandPanelScrollFixture(edge: edge)
        defer { fixture.close() }
        let hosting = try XCTUnwrap(fixture.controller.panel.contentView)
        fixture.controller.show()
        let label = edge.map { "\($0) dock" } ?? "notch"
        try await waitUntil("\(label) lays out its complete root and quota rows", hosting: hosting) {
            guard let scroll = self.firstScrollView(in: hosting), let document = scroll.documentView else { return false }
            return fixture.observation.height > fixture.cardFrame.height + 200
                && document.bounds.height > 0 && scroll.contentView.bounds.height > 0
        }
        let scroll = try XCTUnwrap(firstScrollView(in: hosting))
        let document = try XCTUnwrap(scroll.documentView)
        let viewportBefore = topLeftRect(scroll.contentView.convert(scroll.contentView.bounds, to: hosting), in: hosting)
        let card = fixture.cardFrame

        XCTAssertGreaterThan(fixture.canvas.height, card.height + 200)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height + 200,
                             "\(label): the complete root must offer a genuinely overflowing viewport")
        XCTAssertGreaterThan(viewportBefore.height, 80, "\(label): the viewport must retain usable space")
        XCTAssertTrue(card.insetBy(dx: -1, dy: -1).contains(viewportBefore),
                      "\(label): viewport \(viewportBefore) must stay inside short card \(card), not use the full canvas")
        // The footer's buttons are 28 pt tall and sit below the scrolling content, inside the card.
        let footer = CGRect(x: viewportBefore.minX, y: viewportBefore.maxY,
                            width: viewportBefore.width, height: card.maxY - viewportBefore.maxY)
        XCTAssertGreaterThanOrEqual(footer.height, 28, "\(label): the viewport must end above room for the footer")
        try assertPainted(footer, in: hosting, label: label)

        let previousOffset = scroll.contentView.bounds.origin.y
        let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
        scroll.contentView.scroll(to: CGPoint(x: scroll.contentView.bounds.origin.x, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitUntil("\(label) scrolls to its last content row", hosting: hosting) {
            abs(scroll.contentView.bounds.origin.y - bottom) < 1
        }
        XCTAssertNotEqual(scroll.contentView.bounds.origin.y, previousOffset,
                          "\(label): scrolling must move the actual NSScrollView document")
        let viewportAfter = topLeftRect(scroll.contentView.convert(scroll.contentView.bounds, to: hosting), in: hosting)
        XCTAssertEqual(viewportAfter.minY, viewportBefore.minY, accuracy: 1)
        XCTAssertEqual(viewportAfter.height, viewportBefore.height, accuracy: 1,
                       "\(label): scrolling must not move the footer below the viewport")
        try assertPainted(footer, in: hosting, label: label)
    }

    /// The footer's controls are drawn in the panel's secondary colour over its black card: something in `rect` has to
    /// be brighter than the card, or the card's mask has cut the footer off.
    @MainActor
    private func assertPainted(_ rect: CGRect, in hosting: NSView, label: String) throws {
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let sx = CGFloat(bitmap.pixelsWide) / hosting.bounds.width, sy = CGFloat(bitmap.pixelsHigh) / hosting.bounds.height
        var brightest: CGFloat = 0
        for y in stride(from: Int(rect.minY * sy), to: Int(rect.maxY * sy), by: 1) where y >= 0 && y < bitmap.pixelsHigh {
            for x in stride(from: Int(rect.minX * sx), to: Int(rect.maxX * sx), by: 1) where x >= 0 && x < bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                brightest = max(brightest, (color.redComponent + color.greenComponent + color.blueComponent) / 3)
            }
        }
        XCTAssertGreaterThan(brightest, 0.25, "\(label): the footer must be painted inside the card")
    }

    @MainActor
    private func waitUntil(_ what: String, hosting: NSView, timeout: TimeInterval = 5,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            hosting.layoutSubtreeIfNeeded()
            hosting.window?.displayIfNeeded()
            guard Date() < deadline else {
                XCTFail("Timed out waiting until \(what)")
                throw IslandPanelScrollTimeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        hosting.layoutSubtreeIfNeeded()
        hosting.window?.displayIfNeeded()
    }

    @MainActor
    private func topLeftRect(_ rect: CGRect, in hosting: NSView) -> CGRect {
        hosting.isFlipped ? rect : CGRect(x: rect.minX, y: hosting.bounds.height - rect.maxY,
                                         width: rect.width, height: rect.height)
    }

    @MainActor
    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.firstScrollView(in: $0) }.first
    }
}

@MainActor
private final class IslandPanelScrollFixture {
    let domain = "app.agenthud.tests.root-scroll.\(UUID().uuidString)"
    let defaults: UserDefaults
    let controller: IslandWindowController
    let canvas: CGSize
    let cardFrame: CGRect
    let observation: IslandPanelScrollObservation

    init(edge: HUDEdge?) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let observedHeight = IslandPanelScrollObservation()
        observation = observedHeight
        let agents = (0..<24).map {
            AgentDescriptor(id: "scroll-quota-\($0)", vendor: "Claude", model: "Quota \($0)", source: "Test", enabled: true)
        }
        let consumers = (0..<26).map {
            AgentDescriptor(id: "scroll-model-\($0)", vendor: $0.isMultiple(of: 2) ? "Claude" : "Codex",
                            model: "Model \($0)", source: "Test", enabled: true)
        }
        let settings = SettingsStore(defaults: defaults, defaultAgents: agents)
        settings.update {
            $0.showIslandQuota = true
            $0.showIslandTokens = true
            $0.showIslandSessions = false
        }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        let now = Date()
        store.replace(report: UsageReport(generatedAt: now, snapshots: agents.map {
            UsageSnapshot(agentId: $0.id, remainingPct: 50, resetAt: now.addingTimeInterval(3600),
                          windowDuration: 5 * 3600, updatedAt: now)
        }, sessions: [], discoveredAgents: agents, consumers: consumers, usage: consumers.flatMap { consumer in
            (0..<24).map { hour in
                UsageBucket(start: now.addingTimeInterval(-Double(hour + 1) * 3600), agentId: consumer.id,
                            tokensIn: 10000, tokensOut: 1000)
            }
        }))
        let width = IslandController.expandedWidth + ((edge?.isHorizontal ?? true) ? 2 * NotchGeometry.expandedTopRadius : 0)
        canvas = CGSize(width: width, height: 760)
        let y: CGFloat
        switch edge {
        case .bottom: y = canvas.height - 420
        case .left, .right: y = 210
        default: y = 0
        }
        cardFrame = CGRect(x: 0, y: y, width: width, height: 420)
        let strip: CGRect
        switch edge {
        case .bottom: strip = CGRect(x: 100, y: canvas.height - 32, width: 280, height: 32)
        case .left: strip = CGRect(x: 0, y: 0, width: 32, height: canvas.height)
        case .right: strip = CGRect(x: width - 32, y: 0, width: 32, height: canvas.height)
        default: strip = CGRect(x: 100, y: 0, width: 280, height: 32)
        }
        var root = IslandRootView(store: store, isOpen: true,
            collapsedSize: edge == nil ? CGSize(width: 216, height: 32) : strip.size,
            collapsedTopRadius: 8, collapsedBottomRadius: 12, lightBorder: false)
        root.presentationSize = canvas
        root.presentationFrame = cardFrame
        root.animatesGeometry = false
        root.onContentHeight = { observedHeight.height = $0 }
        if let edge {
            root.hidesSilhouette = true
            root.edge = edge
            root.logoQueueFrame = strip
            root.logoQueue = LogoQueueConfig(items: (0..<20).map { _ in
                LogoQueueItem(vendor: "Claude")
            }, placement: ScreenPlacement(mode: .logos, edge: edge, logoSize: 24))
        }
        controller = IslandWindowController(
            frame: CGRect(x: -20000, y: -20000, width: canvas.width, height: canvas.height), rootView: root)
    }

    func close() {
        controller.panel.orderOut(nil)
        defaults.removePersistentDomain(forName: domain)
    }
}

@MainActor
private final class IslandPanelScrollObservation {
    var height: CGFloat = 0
}

private struct IslandPanelScrollTimeout: Error {}
