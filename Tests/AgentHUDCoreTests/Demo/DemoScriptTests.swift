import XCTest
@testable import AgentHUDCore

final class DemoScriptTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAScriptReadsEveryKindOfStepFromJSONAndPutsThemInOrder() throws {
        let json = #"""
        {"running": ["s2"], "used": {"codex": 84}, "repeatAfter": 5, "steps": [
          {"at": 9, "do": "panel", "open": true},
          {"at": 1, "do": "work", "session": "s1"},
          {"at": 2, "do": "ask", "request": "demo-edit"},
          {"at": 3, "do": "answer", "request": "demo-edit"},
          {"at": 4, "do": "reply", "session": "s1", "message": "Done."},
          {"at": 5, "do": "rest", "session": "s2"},
          {"at": 6, "do": "quota", "agent": "codex", "used": 91}
        ]}
        """#
        let script = try JSONDecoder().decode(DemoScript.self, from: Data(json.utf8))
        XCTAssertEqual(script.steps.map(\.at), [1, 2, 3, 4, 5, 6, 9], "Steps play in time order however they were written")
        XCTAssertEqual(script.steps.map(\.action), [
            .work(session: "s1"), .ask(request: "demo-edit"), .answer(request: "demo-edit"),
            .reply(session: "s1", message: "Done."), .rest(session: "s2"), .quota(agent: "codex", used: 91), .panel(open: true),
        ])
        XCTAssertEqual(script.running, ["s2"])
        XCTAssertEqual(script.used, ["codex": 84])
        XCTAssertEqual(script.repeatAfter, 5)
        XCTAssertEqual(script.length, 9)
        XCTAssertEqual(try JSONDecoder().decode(DemoScript.self, from: JSONEncoder().encode(script)), script)
        XCTAssertThrowsError(try JSONDecoder().decode(DemoScript.self, from: Data(#"{"steps":[{"at":1,"do":"dance"}]}"#.utf8)))
    }

    func testAScriptIsFoundByNameOrAsAFile() throws {
        XCTAssertEqual(try DemoScript.load("showcase"), DemoScript.showcase)
        XCTAssertThrowsError(try DemoScript.load("no-such-script")) {
            XCTAssertEqual($0 as? DemoScript.LoadError, .unknown("no-such-script"))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("demo-script-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"steps":[{"at":2,"do":"work","session":"s3"}]}"#.utf8).write(to: file)
        XCTAssertEqual(try DemoScript.load(file.path).steps, [.init(at: 2, .work(session: "s3"))])
    }

    func testTheStageDecidesWhichDemoSessionsRunAndWhatAWindowReads() {
        var stage = DemoStage(script: DemoScript(used: ["claude-session": 40], steps: []), now: now)
        let idle = DemoData.sessions(now: now, stage: stage)
        XCTAssertTrue(idle.allSatisfy { $0.endedAt != nil }, "A script that starts no session shows none running")

        XCTAssertTrue(stage.apply(.work(session: "s1"), at: now.addingTimeInterval(2)))
        let working = DemoData.sessions(now: now.addingTimeInterval(3), stage: stage)
        XCTAssertNil(working.first { $0.id == "s1" }?.endedAt)
        XCTAssertEqual(working.first { $0.id == "s1" }?.startedAt, now.addingTimeInterval(2))
        XCTAssertNotNil(working.first { $0.id == "s2" }?.endedAt)

        XCTAssertTrue(stage.apply(.rest(session: "s1"), at: now.addingTimeInterval(5)))
        XCTAssertEqual(DemoData.sessions(now: now.addingTimeInterval(6), stage: stage).first { $0.id == "s1" }?.endedAt,
                       now.addingTimeInterval(5))

        func remaining(_ id: String, among rows: [AgentDescriptor]? = nil) -> Double? {
            DemoData.snapshots(for: rows, now: now, stage: stage).first { $0.agentId == id }?.remainingPct
        }
        XCTAssertEqual(remaining(DemoData.claudeAccount.windowID("claude-session")), 60)
        XCTAssertEqual(remaining(DemoData.claudeAccount.windowID("claude-weekly")), 21, "The other windows keep the sample's readings")
        XCTAssertTrue(stage.apply(.quota(agent: "codex", used: 91), at: now))
        XCTAssertEqual(remaining(DemoData.codexAccount.windowID("codex")), 9)
        XCTAssertEqual(remaining(DemoData.codexAccount.windowID("codex:spark:primary")), 82, "A reading for codex is the plan window's alone")
        XCTAssertTrue(stage.apply(.quota(agent: "cursor", used: 50), at: now))
        XCTAssertEqual(remaining("cursor", among: DemoData.everyAgent), 50, "Another vendor's row is named by its id")
        XCTAssertEqual(DemoData.sessions(now: now).filter { $0.endedAt == nil }.map(\.id), ["s1", "s2"],
                       "Without a stage the first two sessions run")
    }

    func testAReplyEndsTheSessionAndIsAnnouncedOnceEvenWhenTheScriptStartsOver() {
        let script = DemoScript(steps: [.init(at: 1, .work(session: "s2")), .init(at: 2, .reply(session: "s2", message: "Paginated."))])
        var stage = DemoStage(script: script, now: now)
        stage.apply(.work(session: "s2"), at: now.addingTimeInterval(1))
        XCTAssertTrue(stage.apply(.reply(session: "s2", message: "Paginated."), at: now.addingTimeInterval(2)))
        let report = DemoUsageProvider.report(agents: DemoData.everyAgent, historyHours: 48, now: now.addingTimeInterval(2), stage: stage)
        XCTAssertEqual(report.completions.map(\.sessionID), ["s2"])
        XCTAssertEqual(report.completions.first?.vendor, "Codex")
        XCTAssertEqual(report.completions.first?.message, "Paginated.")
        XCTAssertEqual(report.completions.first?.model, "gpt-6-astra")
        XCTAssertEqual(report.completions.first?.completedAt, now.addingTimeInterval(2))
        XCTAssertNotNil(report.sessions.first { $0.id == "s2" }?.endedAt)

        var events = IslandEventTracker(startedAt: now)
        let first = events.update(report: report, agents: DemoData.everyAgent, now: now.addingTimeInterval(2))
        XCTAssertEqual(first.completions.map(\.sessionID), ["s2"], "The island gets the reply as it gets a real one")

        stage.restart(script: script, now: now.addingTimeInterval(10))
        stage.apply(.work(session: "s2"), at: now.addingTimeInterval(11))
        stage.apply(.reply(session: "s2", message: "Paginated."), at: now.addingTimeInterval(12))
        let again = DemoUsageProvider.report(agents: DemoData.everyAgent, historyHours: 48, now: now.addingTimeInterval(12), stage: stage)
        XCTAssertEqual(again.completions.count, 2)
        XCTAssertEqual(Set(again.completions.map(\.id)).count, 2, "A second round's reply is a new turn")
        XCTAssertEqual(events.update(report: again, agents: DemoData.everyAgent, now: now.addingTimeInterval(12)).completions.count, 1)
    }

    func testRequestsQueueWithoutChangingTheReportAndTheShowcaseCrossesAQuotaThreshold() {
        var stage = DemoStage(script: .showcase, now: now)
        XCTAssertFalse(stage.apply(.ask(request: "demo-edit"), at: now.addingTimeInterval(8)))
        XCTAssertFalse(stage.apply(.ask(request: "demo-edit"), at: now.addingTimeInterval(9)), "Asking twice queues one")
        XCTAssertEqual(stage.requests.map(\.id), ["demo-edit"])
        XCTAssertEqual(stage.requests.first?.at, now.addingTimeInterval(8))
        XCTAssertFalse(stage.apply(.answer(request: "demo-edit"), at: now.addingTimeInterval(14)))
        XCTAssertTrue(stage.requests.isEmpty)
        XCTAssertFalse(stage.apply(.panel(open: true), at: now))

        // The showcase's quota step must raise the alert it is there to show.
        var events = IslandEventTracker(startedAt: now)
        let agents = DemoData.everyAgent
        let before = DemoUsageProvider.report(agents: agents, historyHours: 48, now: now.addingTimeInterval(20), stage: stage)
        XCTAssertTrue(events.update(report: before, agents: agents, now: now.addingTimeInterval(20)).quotaAlerts.isEmpty)
        guard case .quota(let agent, let used)? = DemoScript.showcase.steps.map(\.action).first(where: {
            if case .quota = $0 { return true } else { return false }
        }) else { return XCTFail("The showcase has no quota step") }
        stage.apply(.quota(agent: agent, used: used), at: now.addingTimeInterval(24))
        let after = DemoUsageProvider.report(agents: agents, historyHours: 48, now: now.addingTimeInterval(24), stage: stage)
        XCTAssertFalse(events.update(report: after, agents: agents, now: now.addingTimeInterval(24)).quotaAlerts.isEmpty,
                       "Crossing nine tenths used raises the quota alert")
    }
}
