import AppKit
import SwiftUI
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

final class HoverPanelLayoutTests: XCTestCase {
    @MainActor
    func testLongContentScrollsAboveAFixedFooterAndReportsItsNaturalHeight() async throws {
        _ = NSApplication.shared
        let domain = "app.agenthud.tests.panel-layout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let agents = (0..<32).map {
            AgentDescriptor(id: "quota-\($0)", vendor: "Claude", model: "Quota \($0)", source: "Test", enabled: true)
        }
        let settings = SettingsStore(defaults: defaults, defaultAgents: agents)
        settings.update {
            $0.showIslandQuota = true
            $0.showIslandTokens = false
            $0.showIslandSessions = false
        }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        let now = Date()
        store.replace(report: UsageReport(generatedAt: now, snapshots: agents.map {
            UsageSnapshot(agentId: $0.id, remainingPct: 50, resetAt: now.addingTimeInterval(3600),
                          windowDuration: 5 * 3600, updatedAt: now)
        }, sessions: []))

        let observation = HeightObservation()
        let width = IslandController.expandedWidth + 2 * NotchGeometry.expandedTopRadius
        let cap: CGFloat = 320
        var root = IslandRootView(store: store, isOpen: true, collapsedSize: CGSize(width: 216, height: 32),
                                  collapsedTopRadius: 16, collapsedBottomRadius: 12, lightBorder: false)
        root.presentationSize = CGSize(width: width, height: cap)
        root.animatesGeometry = false
        root.onContentHeight = { observation.value = $0 }
        let controller = IslandWindowController(
            frame: CGRect(x: -20000, y: -20000, width: width, height: cap), rootView: root)
        let window = controller.panel
        let hosting = try XCTUnwrap(window.contentView)
        controller.show()
        defer { window.orderOut(nil) }

        try await waitUntil("the long panel lays out its overflowing content", hosting: hosting) {
            guard let scroll = self.firstScrollView(in: hosting), let document = scroll.documentView else { return false }
            return observation.value > cap && document.bounds.height > scroll.contentView.bounds.height + 100
        }
        let scroll = try XCTUnwrap(firstScrollView(in: hosting))
        let document = try XCTUnwrap(scroll.documentView)
        let viewportBefore = topLeftRect(scroll.contentView.convert(scroll.contentView.bounds, to: hosting), in: hosting)
        // The footer's 28 pt controls sit below the scrolling content, above the panel's bottom inset.
        let footer = CGRect(x: viewportBefore.minX, y: viewportBefore.maxY, width: viewportBefore.width,
                            height: cap - HoverPanelView.notchInsets.bottom - viewportBefore.maxY)
        XCTAssertGreaterThanOrEqual(footer.height, 28, "The scrolling content must end above room for the footer")
        XCTAssertGreaterThan(brightest(in: footer, of: hosting), 0.25, "The footer must be drawn below the content")
        XCTAssertEqual(window.frame.height, cap, accuracy: 1)
        let naturalHeight = controller.contentHeight(for: root)
        XCTAssertGreaterThan(naturalHeight, cap + 100, "Natural measurement must ignore the presentation height")
        XCTAssertEqual(observation.value, naturalHeight, accuracy: 2,
                       "Height preferences must report all natural content, rather than the capped viewport")

        let previousOffset = scroll.contentView.bounds.origin.y
        let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
        scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await waitUntil("the panel reaches the bottom of its content", hosting: hosting) {
            abs(scroll.contentView.bounds.origin.y - bottom) < 1
        }
        XCTAssertNotEqual(scroll.contentView.bounds.origin.y, previousOffset)
        let viewportAfter = topLeftRect(scroll.contentView.convert(scroll.contentView.bounds, to: hosting), in: hosting)
        XCTAssertEqual(viewportAfter.maxY, viewportBefore.maxY, accuracy: 1, "Scrolling must not move the footer")
        XCTAssertGreaterThan(brightest(in: footer, of: hosting), 0.25)

        // SwiftUI updates the content while the window remains capped. Its preference must still report the
        // shorter natural height, so the owner can shrink the window instead of retaining an empty viewport.
        settings.update { $0.showIslandQuota = false }
        try await waitUntil("shorter content reports a height below the cap", hosting: hosting) {
            observation.value > 0 && observation.value < cap - 100
        }
        let shorterHeight = controller.contentHeight(for: root).rounded()
        XCTAssertEqual(observation.value, shorterHeight, accuracy: 2)
        XCTAssertLessThan(shorterHeight, naturalHeight)
        root.presentationSize = CGSize(width: width, height: shorterHeight)
        controller.setRootView(root)
        controller.setFrame(CGRect(x: -20000, y: -20000, width: width, height: shorterHeight))
        try await waitUntil("the shorter panel restores its natural height", hosting: hosting) {
            guard let scroll = self.firstScrollView(in: hosting), let document = scroll.documentView else { return false }
            return document.bounds.height <= scroll.contentView.bounds.height + 1
        }
        XCTAssertEqual(window.frame.height, shorterHeight, accuracy: 1)
        XCTAssertEqual(observation.value, shorterHeight, accuracy: 2,
                       "Restoring a shorter viewport must preserve the natural height report")
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
                throw LayoutTimeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        hosting.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.firstScrollView(in: $0) }.first
    }

    @MainActor
    private func topLeftRect(_ rect: CGRect, in hosting: NSView) -> CGRect {
        hosting.isFlipped ? rect : CGRect(x: rect.minX, y: hosting.bounds.height - rect.maxY,
                                         width: rect.width, height: rect.height)
    }

    /// The brightest opaque pixel in `rect`, top-left based, as the mean of its components: the panel's controls are
    /// drawn in its secondary colour over a black card.
    @MainActor
    private func brightest(in rect: CGRect, of hosting: NSView) -> CGFloat {
        hosting.window?.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return 0 }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let sx = CGFloat(bitmap.pixelsWide) / hosting.bounds.width, sy = CGFloat(bitmap.pixelsHigh) / hosting.bounds.height
        var brightest: CGFloat = 0
        for y in Int(rect.minY * sy)..<Int(rect.maxY * sy) where y >= 0 && y < bitmap.pixelsHigh {
            for x in Int(rect.minX * sx)..<Int(rect.maxX * sx) where x >= 0 && x < bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                brightest = max(brightest, (color.redComponent + color.greenComponent + color.blueComponent) / 3)
            }
        }
        return brightest
    }
}

@MainActor
private final class HeightObservation {
    var value: CGFloat = 0
}

private struct LayoutTimeout: Error {}
