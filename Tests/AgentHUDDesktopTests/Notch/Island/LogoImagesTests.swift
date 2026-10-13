import AppKit
import AgentHUDCore
import XCTest
@testable import AgentHUDDesktop

@MainActor
final class LogoImagesTests: XCTestCase {
    func testBundledTransparentPaddingUsesTopDownImageCoordinates() throws {
        // Native pixel sizes avoid resampling. DeepSeek's unequal top/bottom padding catches a y flip.
        let samples: [(vendor: String, side: Int, pixels: CGRect)] = [
            ("DeepSeek", 640, CGRect(x: 0, y: 80, width: 640, height: 471)),
            ("GitHub Copilot", 640, CGRect(x: 0, y: 66, width: 640, height: 508)),
            ("OpenCode", 256, CGRect(x: 25, y: 0, width: 206, height: 256)),
        ]
        for sample in samples {
            let key = LogoImages.Key(vendor: sample.vendor, side: sample.side, outline: 0, light: true)
            let image = try XCTUnwrap(LogoImages.image(key))
            XCTAssertEqual(image.width, sample.side)
            let bounds = LogoImages.visibleBounds(key)
            let side = CGFloat(sample.side)
            XCTAssertEqual(bounds.minX, sample.pixels.minX / side, accuracy: 0.000001, sample.vendor)
            XCTAssertEqual(bounds.minY, sample.pixels.minY / side, accuracy: 0.000001, sample.vendor)
            XCTAssertEqual(bounds.width, sample.pixels.width / side, accuracy: 0.000001, sample.vendor)
            XCTAssertEqual(bounds.height, sample.pixels.height / side, accuracy: 0.000001, sample.vendor)
        }
    }

    func testVisibleBoundsContainTheActualOutlinedPixelsAtBothDisplayScales() throws {
        for vendor in ["Claude", "DeepSeek", "GitHub Copilot", "OpenCode"] {
            for scale in [1, 2] {
                for outline in [0, 1] {
                    let key = LogoImages.Key(vendor: vendor, side: 30 * scale, outline: outline, light: false)
                    let image = try XCTUnwrap(LogoImages.image(key))
                    XCTAssertEqual(image.width, key.side + outline * 2)
                    let bounds = LogoImages.visibleBounds(key)
                    let pixels = try pixelBounds(of: image)
                    XCTAssertEqual(bounds.minX * CGFloat(image.width), pixels.minX, accuracy: 0.000001, vendor)
                    XCTAssertEqual(bounds.minY * CGFloat(image.height), pixels.minY, accuracy: 0.000001, vendor)
                    XCTAssertEqual(bounds.maxX * CGFloat(image.width), pixels.maxX, accuracy: 0.000001, vendor)
                    XCTAssertEqual(bounds.maxY * CGFloat(image.height), pixels.maxY, accuracy: 0.000001, vendor)
                    XCTAssertGreaterThan(bounds.width, 0)
                    XCTAssertGreaterThan(bounds.height, 0)
                    XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(bounds))
                }
            }
        }
    }

    func testHairlineIsIncludedBeyondTheNominalLogo() throws {
        for scale in [1, 2] {
            let key = LogoImages.Key(vendor: "Claude", side: 30 * scale, outline: 1, light: false)
            let image = try XCTUnwrap(LogoImages.image(key))
            let bounds = LogoImages.visibleBounds(key)
            let nominal = CGRect(x: 1, y: 1, width: key.side, height: key.side)
            XCTAssertLessThan(bounds.minX * CGFloat(image.width), nominal.minX)
            XCTAssertLessThan(bounds.minY * CGFloat(image.height), nominal.minY)
            XCTAssertGreaterThan(bounds.maxX * CGFloat(image.width), nominal.maxX)
            XCTAssertGreaterThan(bounds.maxY * CGFloat(image.height), nominal.maxY)
        }
    }

    func testBitmapAndBoundsAreStableWhicheverCachedValueIsRequestedFirst() throws {
        let key = LogoImages.Key(vendor: "DeepSeek", side: 60, outline: 1, light: false)
        LogoImages.invalidate()
        let bounds = LogoImages.visibleBounds(key)
        let image = try XCTUnwrap(LogoImages.image(key))
        for _ in 0..<3 {
            XCTAssertTrue(image === LogoImages.image(key))
            XCTAssertEqual(LogoImages.visibleBounds(key), bounds)
        }
    }

    func testThirtySixPointWorkingBotsFitTheExistingCollapsedSlack() throws {
        let side: CGFloat = 36, scale: CGFloat = 2
        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        for vendor in AgentArtwork.allVendors {
            let form = try XCTUnwrap(BotForm.form(for: vendor))
            var placements: [(view: LogoQueueLayerView, canvas: CGRect, edge: HUDEdge)] = []
            for edge in HUDEdge.allCases {
                let placement = ScreenPlacement(edge: edge, logoSize: Double(side), logoEdgeDistance: 0)
                let config = LogoQueueConfig(items: [LogoQueueItem(vendor: vendor, isWorking: true)],
                                             placement: placement, settings: Settings())
                let strip = NotchGeometry.stripRect(queue: config.size, frame: screen, placement: placement)
                let geometry = NotchGeometry(screenFrame: screen, mode: .logos, edge: edge, hasNotch: false,
                                             rect: strip, cornerRadius: 10, backingScale: scale, menuBarHeight: 24)
                let view = LogoQueueLayerView()
                view.setFrameSize(strip.size)
                view.apply(config: config, light: false, scale: scale, animates: false)
                let canvas = CGRect(x: geometry.islandFrame.minX - strip.minX,
                                    y: strip.maxY - geometry.islandFrame.maxY,
                                    width: geometry.islandFrame.width, height: geometry.islandFrame.height)
                placements.append((view, canvas, edge))
            }
            var motion = BotMotion(seed: 3)
            motion.spin = form.spec.spin
            motion.set(.working, at: 0)
            for frame in 0...900 {
                motion.step(to: Double(frame) / 30)
                guard frame.isMultiple(of: 30), motion.morph > 0 else { continue }
                let image = try XCTUnwrap(BotRenderer.image(form, motion: motion, side: side * scale, outline: 1))
                let extent = BotActor.extent(side: side, scale: scale, outline: 1)
                let transform = BotActor.transform(motion.pose, side: side, yRunsDown: true)
                let pixels = try transformedPixels(of: image, extent: extent, transform: transform)
                for (view, canvas, edge) in placements {
                    let actor = try XCTUnwrap(view.actors.first ?? nil)
                    let shown = pixels.offsetBy(dx: actor.layer.position.x, dy: actor.layer.position.y)
                    let message = "\(vendor), \(edge), \(Double(frame) / 30)s: \(shown) exceeds \(canvas)"
                    // The physical screen edge intentionally clips outward decoration. The other three
                    // sides must fit the actual collapsed window, rather than its transparent bot canvas.
                    if edge != .left { XCTAssertGreaterThanOrEqual(shown.minX, canvas.minX, message) }
                    if edge != .right { XCTAssertLessThanOrEqual(shown.maxX, canvas.maxX, message) }
                    if edge != .top { XCTAssertGreaterThanOrEqual(shown.minY, canvas.minY, message) }
                    if edge != .bottom { XCTAssertLessThanOrEqual(shown.maxY, canvas.maxY, message) }
                }
            }
        }
    }

    private func transformedPixels(of image: CGImage, extent: CGFloat,
                                   transform: CGAffineTransform) throws -> CGRect {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let unit = extent / CGFloat(image.width)
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for y in 0..<image.height {
            for x in 0..<image.width where bytes[y * image.bytesPerRow + x * 4 + 3] > 0 {
                for corner in [CGPoint(x: x, y: y), CGPoint(x: x + 1, y: y),
                               CGPoint(x: x, y: y + 1), CGPoint(x: x + 1, y: y + 1)] {
                    let point = CGPoint(x: corner.x * unit - extent / 2,
                                        y: corner.y * unit - extent / 2).applying(transform)
                    minX = min(minX, point.x); minY = min(minY, point.y)
                    maxX = max(maxX, point.x); maxY = max(maxY, point.y)
                }
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// NSBitmapImageRep handles the image's pixel layout independently of the cache's RGBA scanner.
    private func pixelBounds(of image: CGImage) throws -> CGRect {
        let bitmap = NSBitmapImageRep(cgImage: image)
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThanOrEqual(maxX, minX)
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
