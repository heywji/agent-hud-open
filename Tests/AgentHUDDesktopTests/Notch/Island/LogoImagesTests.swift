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
