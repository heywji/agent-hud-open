import AppKit
import AVFoundation
import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

final class HUDRecorderTests: XCTestCase {
    func testARegionIsFourNumbersInPoints() {
        XCTAssertEqual(HUDRecorder.Options.region("10, 20,300,200"), CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertNil(HUDRecorder.Options.region("10,20,300"))
        XCTAssertNil(HUDRecorder.Options.region("10,20,0,200"), "An empty region records nothing")
        XCTAssertNil(HUDRecorder.Options.region("left,top,300,200"))
    }

    func testTheRecordingOptionsAreReadFromTheCommandLine() {
        let options = DesktopLaunchOptions.parse(["app", "--record", "~/take.mov", "--record-seconds", "12.5", "--record-fps", "30",
                                                  "--record-region", "0,0,640,480"])
        XCTAssertEqual(options.recordPath, "~/take.mov")
        XCTAssertEqual(options.recordSeconds, 12.5)
        XCTAssertEqual(options.recordFPS, 30)
        XCTAssertEqual(options.recordRegion, "0,0,640,480")
        XCTAssertFalse(options.demo, "Recording does not need the demo")
    }

    /// Alpha of the pixel at a point given in global screen coordinates.
    private func alpha(of image: CGImage, at point: CGPoint, on screen: NSScreen) throws -> UInt8 {
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let scale = screen.backingScaleFactor
        let x = Int((point.x - screen.frame.minX) * scale), y = Int((screen.frame.maxY - point.y) * scale)
        // Premultiplied alpha first in a little-endian word: blue, green, red, alpha.
        return data[min(image.height - 1, max(0, y)) * image.bytesPerRow + min(image.width - 1, max(0, x)) * 4 + 3]
    }

    @MainActor
    func testAFrameHoldsTheHUDWhereItIsAndIsClearEverywhereElse() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let key = ScreenIdentity.key(for: screen)
        let domain = "app.agenthud.tests.recorder.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.agents)
        settings.update { $0.screens[key] = ScreenPlacement(mode: .notch) }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings, accessAllowed: { false })
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: Date()))
        let hud = ScreenHUD(key: key, screen: screen, store: store, settings: settings)
        defer { hud.close() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hud-frame-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try HUDRecorder(options: .init(url: url), screen: screen) {
            [.init(window: hud.glow.panel, bounds: hud.island.panel.frame.insetBy(dx: -120, dy: -120)),
             .init(window: hud.island.panel, bounds: nil)]
        }

        var image = try XCTUnwrap(recorder.snapshot())
        XCTAssertEqual(image.width, Int((screen.frame.width * screen.backingScaleFactor / 2).rounded(.up)) * 2)
        let island = hud.geometry.rect, centre = CGPoint(x: island.midX, y: island.midY)
        // The island's layers are drawn a moment after the window is shown, so the frame is taken again until they are.
        let deadline = Date().addingTimeInterval(2)
        while try alpha(of: image, at: centre, on: screen) != 255, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            image = try XCTUnwrap(recorder.snapshot())
        }
        // CI's runner, a virtual display with Reduce Motion on, never draws them: there is no picture to check there.
        try XCTSkipIf(try alpha(of: image, at: centre, on: screen) != 255 && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "this display did not draw the island within 2 s with Reduce Motion on")
        XCTAssertEqual(try alpha(of: image, at: centre, on: screen), 255, "The island is solid")
        XCTAssertEqual(try alpha(of: image, at: CGPoint(x: screen.frame.midX, y: screen.frame.minY + 40), on: screen), 0,
                       "Nothing else on the display is in the picture")
        XCTAssertEqual(try alpha(of: image, at: CGPoint(x: island.minX - 400, y: island.midY), on: screen), 0,
                       "The glow's window spans the display, its picture does not")
    }

    /// The layer SwiftUI makes for a stroked rounded rectangle: a border and nothing else.
    private func outline(_ frame: CGRect, radius: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.frame = frame
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = CGColor(gray: 1, alpha: 1)
        return layer
    }

    @MainActor
    func testOnlyAContinuousBorderWithNoRoomForItsCornersHasStrayLines() {
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        let capsule = outline(CGRect(x: 22, y: 6, width: 256, height: 48), radius: 24)
        root.addSublayer(capsule)
        // One at each tip, as far past the middle as the two corners overrun the side.
        let overrun = 24 * 1.528665 - 24
        let lines = HUDRecorder.strayBorderLines(under: root).sorted { $0.minX < $1.minX }
        XCTAssertEqual(lines.count, 2)
        for (line, x) in zip(lines, [22.0, 277.0]) {
            XCTAssertEqual(line.minX, x, accuracy: 0.001)
            XCTAssertEqual(line.width, 1, accuracy: 0.001)
            XCTAssertEqual(line.minY, 30 - overrun, accuracy: 0.001)
            XCTAssertEqual(line.maxY, 30 + overrun, accuracy: 0.001)
        }

        capsule.isHidden = true
        XCTAssertTrue(HUDRecorder.strayBorderLines(under: root).isEmpty)
        capsule.isHidden = false
        capsule.cornerCurve = .circular
        XCTAssertTrue(HUDRecorder.strayBorderLines(under: root).isEmpty, "Circular corners are drawn as they are shown")
        capsule.cornerCurve = .continuous
        capsule.cornerRadius = 12
        XCTAssertTrue(HUDRecorder.strayBorderLines(under: root).isEmpty, "Two corners of 12 fit a side of 48")
        capsule.cornerRadius = 16
        XCTAssertTrue(HUDRecorder.strayBorderLines(under: root).isEmpty, "A line that stays inside the outline is left alone")
        capsule.cornerRadius = 24
        capsule.borderWidth = 0
        XCTAssertTrue(HUDRecorder.strayBorderLines(under: root).isEmpty)

        // Upright, in a layer that is itself moved: the lines are along the short sides, where the picture has them.
        let holder = CALayer()
        holder.frame = CGRect(x: 100, y: 20, width: 100, height: 270)
        holder.addSublayer(outline(CGRect(x: 10, y: 5, width: 48, height: 256), radius: 24))
        root.addSublayer(holder)
        let upright = HUDRecorder.strayBorderLines(under: root).sorted { $0.minY < $1.minY }
        XCTAssertEqual(upright.count, 2)
        for (line, y) in zip(upright, [25.0, 280.0]) {
            XCTAssertEqual(line.minY, y, accuracy: 0.001)
            XCTAssertEqual(line.height, 1, accuracy: 0.001)
            XCTAssertEqual(line.minX, 134 - overrun, accuracy: 0.001)
            XCTAssertEqual(line.maxX, 134 + overrun, accuracy: 0.001)
        }
    }

    /// A black capsule with a white outline on a grey ground, drawn as a frame draws it. What the software renderer adds
    /// is a white line up the outermost column of each tip, 12 pt either side of the middle; the capsule's own curve has
    /// left that column 7 pt from the middle.
    @MainActor
    func testACapsulesOutlineIsDrawnWithoutALinePastItsTipsAndWithoutAHoleThere() throws {
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: 300, height: 60)
        let ground = CALayer()
        ground.frame = root.bounds
        ground.backgroundColor = CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        root.addSublayer(ground)
        let card = CGRect(x: 22, y: 6, width: 256, height: 48)
        let fill = CALayer()
        fill.frame = card
        fill.cornerRadius = 24
        fill.cornerCurve = .continuous
        fill.backgroundColor = CGColor(gray: 0, alpha: 1)
        root.addSublayer(fill)
        let border = outline(card, radius: 24)
        root.addSublayer(border)
        let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.scaleBy(x: 2, y: 2)
        HUDRecorder.render(root, in: context)
        XCTAssertEqual(border.cornerCurve, .continuous, "The layer is as it was")
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // Blue and alpha of the pixel at the middle of a point.
        func pixel(_ x: Int, _ y: Int) -> (grey: UInt8, alpha: UInt8) {
            let at = (y * 2 + 1) * context.bytesPerRow + (x * 2 + 1) * 4
            return (data[at], data[at + 3])
        }

        for x in [22, 277] {
            for y in [30 - 12, 30 - 9, 30 + 8, 30 + 11] {
                XCTAssertEqual(pixel(x, y).grey, 128, accuracy: 2, "Column \(x), row \(y): the ground beside the tip, not a line")
                XCTAssertEqual(pixel(x, y).alpha, 255, "Column \(x), row \(y): and no hole")
            }
        }
        XCTAssertEqual(pixel(150, 6).grey, 255, "The outline along a long side")
        XCTAssertEqual(pixel(150, 53).grey, 255)
        XCTAssertEqual(pixel(150, 30).grey, 0, "The capsule")
        XCTAssertEqual(pixel(4, 30).grey, 128, accuracy: 2, "The ground")
    }

    /// The reminder itself in a frame of the real HUD, where its outline is one layer among those SwiftUI makes.
    @MainActor
    func testACompactReminderOnASeparatedDockHasNoLineAtItsTips() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let key = ScreenIdentity.key(for: screen)
        let domain = "app.agenthud.tests.recorder.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = SettingsStore(defaults: defaults, defaultAgents: DemoData.everyAgent)
        settings.update { $0.screens[key] = ScreenPlacement(mode: .logos, edge: .left, separatesAgents: true) }
        let store = UsageStore(provider: DemoUsageProvider(), settings: settings, accessAllowed: { false })
        store.replace(report: DemoUsageProvider.report(agents: settings.agents, historyHours: UsageStore.historyHours, now: Date()))
        let hud = ScreenHUD(key: key, screen: screen, store: store, settings: settings,
                            mouseLocation: { CGPoint(x: -10_000, y: -10_000) })
        defer { hud.close() }
        hud.present(.completion(SessionCompletion(sessionID: "s1", vendor: "Claude", turnID: "reply", task: "Build the iOS dashboard",
                                                  model: "Fable 5.1", startedAt: nil, completedAt: Date())))
        let card = try XCTUnwrap(hud.island.rootView.cardScreenFrame)
        XCTAssertEqual(card.height, IslandRootView.dockCompactSize(edge: .left, collapsedSize: hud.geometry.rect.size).height,
                       "The reminder is the compact pill")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hud-frame-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try HUDRecorder(options: .init(url: url), screen: screen) { [.init(window: hud.island.panel, bounds: nil)] }

        // The pill grows out of the dock; its place is solid once it has arrived.
        let middle = CGPoint(x: card.midX, y: card.maxY - 4)
        var image = try XCTUnwrap(recorder.snapshot())
        let deadline = Date().addingTimeInterval(3)
        while try alpha(of: image, at: middle, on: screen) != 255, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            image = try XCTUnwrap(recorder.snapshot())
        }
        try XCTSkipIf(try alpha(of: image, at: middle, on: screen) != 255 && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "this display did not draw the reminder within 3 s with Reduce Motion on")
        XCTAssertEqual(try alpha(of: image, at: middle, on: screen), 255, "The reminder is solid")
        // The outermost point of each tip, 10 pt from the middle: beside the capsule's curve, where the line was.
        for x in [card.minX + 0.25, card.maxX - 0.75] {
            for y in [card.midY - 10.25, card.midY + 9.25] {
                XCTAssertEqual(try alpha(of: image, at: CGPoint(x: x, y: y), on: screen), 0,
                               "Clear beside the tip at \(x - card.minX), \(y - card.minY)")
            }
        }
    }

    @MainActor
    func testARecordingIsAProRes4444MovieOfTheRegionAtTheDisplaysScale() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let window = NSWindow(contentRect: CGRect(x: screen.frame.minX + 40, y: screen.frame.maxY - 140, width: 120, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 120, height: 60))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemRed.cgColor
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.close() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hud-take-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        var options = HUDRecorder.Options(url: url)
        options.region = CGRect(x: 0, y: 0, width: 300, height: 200)
        options.framesPerSecond = 30
        let recorder = try HUDRecorder(options: options, screen: screen) { [.init(window: window, bounds: nil)] }

        try recorder.start()
        // A slow machine draws its first frames late, so wait for the frames rather than for a fixed time.
        let deadline = Date().addingTimeInterval(5)
        while recorder.frames <= 5, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        await withCheckedContinuation { done in recorder.finish { done.resume() } }

        XCTAssertGreaterThan(recorder.frames, 5)
        let video = try await videoFormat(of: url)
        XCTAssertEqual(video.size, CGSize(width: 300 * screen.backingScaleFactor, height: 200 * screen.backingScaleFactor))
        XCTAssertEqual(video.codec, kCMVideoCodecType_AppleProRes4444, "The codec that keeps the alpha channel")
    }
}

/// A movie's picture size and codec. The macOS 15 SDK's tracks are not Sendable, so they are read here, off the main
/// actor the tests run on, and only the two values go back.
private func videoFormat(of url: URL) async throws -> (size: CGSize, codec: FourCharCode) {
    let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first
    let video = try XCTUnwrap(track)
    let size = try await video.load(.naturalSize)
    let formats = try await video.load(.formatDescriptions)
    return (size, CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)))
}
