import XCTest
@testable import AgentHUDCore
@testable import AgentHUDDesktop

@MainActor
final class DemoScriptRunnerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private final class Log {
        var refreshes = 0
        var requests: [[String]] = []
        var panel: [Bool] = []
    }

    private func runner(_ script: DemoScript) -> (DemoScriptRunner, Log) {
        let log = Log()
        let runner = DemoScriptRunner(script: script, effects: .init(
            refresh: { log.refreshes += 1 },
            showRequests: { log.requests.append($0.map(\.id)) },
            setPanel: { log.panel.append($0) }
        ), now: start)
        return (runner, log)
    }

    override func tearDown() async throws {
        await MainActor.run { DemoStageBox.current = nil }
    }

    func testStepsHappenWhenTheirTimeComesAndEachReachesTheRightPartOfTheApp() {
        let (runner, log) = runner(DemoScript(steps: [
            .init(at: 2, .work(session: "s1")), .init(at: 4, .ask(request: "demo-edit")),
            .init(at: 6, .panel(open: true)), .init(at: 8, .answer(request: "demo-edit")),
        ]))
        XCTAssertEqual(DemoStageBox.current?.running, [:], "The stage is the script's before anything is read")
        XCTAssertEqual(runner.advance(to: start.addingTimeInterval(1)) ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(log.refreshes, 0)

        XCTAssertEqual(runner.advance(to: start.addingTimeInterval(2)) ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(log.refreshes, 1, "A session starting is something the provider reports")
        XCTAssertEqual(DemoStageBox.current?.running["s1"], start.addingTimeInterval(2))

        runner.advance(to: start.addingTimeInterval(4.2))
        XCTAssertEqual(log.requests.last, ["demo-edit"])
        XCTAssertEqual(log.refreshes, 1, "A request is not part of a report")

        runner.advance(to: start.addingTimeInterval(6))
        XCTAssertEqual(log.panel, [true])
        XCTAssertNil(runner.advance(to: start.addingTimeInterval(8)), "A script that plays once ends with its last step")
        XCTAssertEqual(log.requests.last, [])
    }

    func testALateTickPerformsEveryStepItMissedInOrder() {
        let (runner, log) = runner(DemoScript(steps: [
            .init(at: 1, .work(session: "s1")), .init(at: 2, .ask(request: "demo-read")), .init(at: 3, .rest(session: "s1")),
        ]))
        XCTAssertNil(runner.advance(to: start.addingTimeInterval(10)))
        XCTAssertEqual(log.refreshes, 1, "One read covers everything that changed in the tick")
        XCTAssertEqual(DemoStageBox.current?.running, [:])
        XCTAssertEqual(DemoStageBox.current?.ended["s1"], start.addingTimeInterval(10))
        XCTAssertEqual(log.requests.last, ["demo-read"])
    }

    func testARepeatingScriptStartsOverFromItsOpeningStage() {
        let (runner, log) = runner(DemoScript(running: ["s2"], steps: [
            .init(at: 1, .rest(session: "s2")), .init(at: 2, .ask(request: "demo-build")), .init(at: 3, .panel(open: true)),
        ], repeatAfter: 4))
        XCTAssertEqual(runner.advance(to: start.addingTimeInterval(3)) ?? -1, 4, accuracy: 0.001, "The pause before the next round")
        XCTAssertEqual(DemoStageBox.current?.running, [:])

        let round = start.addingTimeInterval(7)
        XCTAssertEqual(runner.advance(to: round) ?? -1, 1, accuracy: 0.001, "The first step of the next round")
        XCTAssertEqual(DemoStageBox.current?.running, ["s2": round])
        XCTAssertEqual(log.requests.last, [], "Requests left waiting are taken back")
        XCTAssertEqual(log.panel, [true, false], "The panel is closed for the new round")

        runner.stop()
        XCTAssertNil(DemoStageBox.current, "Stopping gives the demo its fixed figures back")
    }

    func testARequestAnsweredOnTheHUDIsNotBroughtBackWhileTheScriptStillListsIt() {
        let requests = PermissionRequests.shared
        requests.showDemo([])
        defer { requests.showDemo([]) }
        requests.showDemo([("demo-edit", start)])
        XCTAssertEqual(requests.pending.map(\.id), ["demo-edit"])
        XCTAssertEqual(requests.pending.first?.at, start)
        requests.resolve("demo-edit", .allow)
        requests.showDemo([("demo-edit", start), ("demo-build", start.addingTimeInterval(1))])
        XCTAssertEqual(requests.pending.map(\.id), ["demo-build"])
        requests.showDemo([])
        requests.showDemo([("demo-edit", start.addingTimeInterval(9))])
        XCTAssertEqual(requests.pending.map(\.id), ["demo-edit"], "A later round asks again")
    }

    func testTheScriptOptionTurnsTheDemoOn() {
        let options = DesktopLaunchOptions.parse(["app", "--demo-script", "showcase"])
        XCTAssertTrue(options.demo)
        XCTAssertEqual(options.demoScript, "showcase")
        XCTAssertNil(DesktopLaunchOptions.parse(["app", "--demo"]).demoScript)
    }

    func testTheClockOptionTurnsTheDemoOn() {
        let options = DesktopLaunchOptions.parse(["app", "--demo-clock", "2026-10-12T09:41"])
        XCTAssertTrue(options.demo)
        XCTAssertEqual(options.demoClock, "2026-10-12T09:41")
    }
}
