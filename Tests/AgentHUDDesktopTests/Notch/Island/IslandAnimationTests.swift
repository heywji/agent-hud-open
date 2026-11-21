import AppKit
import SwiftUI
import XCTest
import AgentHUDCore
@testable import AgentHUDDesktop

/// The island and its shadow in real windows: measured expansion, a stable canvas while the silhouette animates, and an
/// unclipped shadow under tall panels.
final class IslandAnimationTests: XCTestCase {
    @MainActor
    func testIslandExpandsToMeasuredHeightAndKeepsItsCanvasWhileAnimating() async throws {
        _ = NSApplication.shared
        let domain = "app.agenthud.tests.animation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        settings.update { $0.collapseDelayMs = 5000; $0.showIslandQuota = true; $0.showIslandTokens = false }
        // This measures the island against its shadow, which follows the notch's shape. A screen left on its own
        // default would run the logo queue instead, which draws no collapsed silhouette to measure.
        for screen in NSScreen.screens {
            settings.update { $0.screens[ScreenIdentity.key(for: screen)] = ScreenPlacement(mode: .notch) }
        }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings)
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: Date()))
        let controller = IslandController(store: store, settings: settings)
        let window = controller.island.panel
        // A machine that reduces motion has no transition to cover, so the island resizes its canvas at once.
        let animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        defer { window.orderOut(nil); controller.shadow.panel.orderOut(nil) }
        await settle(0.1)

        func checkContour() throws {
            let view = try XCTUnwrap(window.contentView)
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let x = rep.pixelsWide / 2
            let occupied = (0..<rep.pixelsHigh).filter { (rep.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.9 }
            let height = CGFloat(occupied.count) * view.bounds.height / CGFloat(rep.pixelsHigh)
            let shadowLayer = controller.shadow.shadowLayer
            let visible = (shadowLayer.presentation() ?? shadowLayer).frame
            let shadowHeight = visible.height - ceil(ShadowWindowController.blur * 3) * 2
            XCTAssertEqual(height, shadowHeight, accuracy: 1, "The island and its shadow must settle to the same contour")
        }

        func measure() -> CGFloat {
            NSHostingView(rootView: HoverPanelView(store: store)
                .frame(width: IslandController.expandedWidth).fixedSize(horizontal: false, vertical: true)).fittingSize.height.rounded()
        }

        let expectedHeight = measure()
        controller.forceOpen()
        XCTAssertEqual(window.frame.height, expectedHeight, "Opening must use the measured height immediately")
        for _ in 0..<8 {
            await settle(0.05)
            XCTAssertEqual(window.frame.height, expectedHeight, "Content measurement must not resize the canvas mid-animation")
        }
        await settle(0.1)
        try checkContour()

        controller.forceCollapse()
        await settle(0.1)
        XCTAssertEqual(window.frame.height, animates ? expectedHeight : controller.geometry.islandFrame.height,
                       "Closing must keep its canvas while the silhouette shrinks")
        controller.forceOpen()
        await settle(0.5)
        XCTAssertEqual(window.frame.height, expectedHeight, "Reopening must cancel the pending canvas shrink")

        settings.update { $0.showIslandQuota = false }
        await settle(0.1)
        let shorterHeight = max(80, measure())
        XCTAssertEqual(window.frame.height, animates ? expectedHeight : shorterHeight,
                       "Live content changes must keep the transition canvas")
        await settle(0.5)
        XCTAssertEqual(window.frame.height, shorterHeight, "Live content height must settle to its measured target")
        controller.forceCollapse()
        await settle(0.5)
        XCTAssertEqual(window.frame, controller.geometry.islandFrame, "Closing must finish at the notch frame")
        try checkContour()
    }

    @MainActor
    func testTallPanelsKeepTheWholeShadowOnScreen() async throws {
        _ = NSApplication.shared
        for screenHeight: CGFloat in [900, 1117, 1440] {
            let screen = CGRect(x: -20000, y: -20000, width: 1728, height: screenHeight)
            let geometry = NotchGeometry(screenFrame: screen, mode: .notch, edge: .top, hasNotch: true,
                rect: CGRect(x: screen.midX - 108, y: screen.maxY - 32, width: 216, height: 32),
                cornerRadius: 12, backingScale: 2, menuBarHeight: 24)
            let controller = ShadowWindowController(geometry: geometry)
            defer { controller.panel.orderOut(nil) }
            let canvas = controller.panel.frame

            func update(height: CGFloat, animated: Bool) {
                let island = geometry.expandedFrame(size: CGSize(width: IslandController.expandedWidth, height: height))
                controller.update(geometry: geometry, island: island, islandRadius: IslandController.expandedRadius,
                                  casts: true, animated: animated)
            }

            func checkClipping() throws {
                XCTAssertEqual(controller.panel.frame, canvas, "The shadow canvas must stay fixed during expansion and collapse")
                let host = try XCTUnwrap(controller.panel.contentView)
                let frame = (controller.shadowLayer.presentation() ?? controller.shadowLayer).frame
                // Only the part above the display's top edge may be clipped.
                XCTAssertTrue(frame.minY >= host.bounds.minY - 0.01 && frame.minX >= host.bounds.minX
                    && frame.maxX <= host.bounds.maxX, "Tall panels must keep their whole shadow (\(screenHeight) pt screen)")
            }

            update(height: screenHeight - 80, animated: false)
            try checkClipping()
            update(height: IslandController.defaultPanelHeight, animated: true)
            await settle(0.1)
            try checkClipping()
            update(height: screenHeight - 80, animated: true)
            await settle(IslandAnimation.duration + 0.1)
            try checkClipping()
        }
    }

    @MainActor
    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
