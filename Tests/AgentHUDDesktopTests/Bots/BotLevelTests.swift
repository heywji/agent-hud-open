import CoreGraphics
import XCTest
@testable import AgentHUDDesktop

@MainActor
final class BotLevelTests: XCTestCase {
    /// Where a finished body's top and bottom fall down the mark, 0 at its top edge and 1 at its bottom.
    private func span(of vendor: String) throws -> (top: CGFloat, bottom: CGFloat) {
        let form = try XCTUnwrap(BotForm.form(for: vendor))
        var top = CGFloat.infinity, bottom = -CGFloat.infinity
        for (index, reach) in form.bodyReach.enumerated() {
            let y = form.spec.center.y + sin(CGFloat(index) * 2 * .pi / CGFloat(BotForm.samples)) * reach + form.spec.settle
            top = min(top, y)
            bottom = max(bottom, y)
        }
        return (top, bottom)
    }

    /// A body that grows off-centre has to settle until it stands level with a plain ball beside it.
    func testAntigravityStandsLevelWithABallBesideIt() throws {
        let dome = try span(of: "Antigravity"), ball = try span(of: "DeepSeek")
        XCTAssertEqual(dome.top, ball.top, accuracy: 0.02)
        XCTAssertEqual(dome.bottom, ball.bottom, accuracy: 0.02)
    }
}
