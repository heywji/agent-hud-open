import XCTest
@testable import AgentHUDCore

/// The sample is the one the iPhone's demo shows (`DemoFleet`): these figures are that demo's, read at the same time.
final class DemoDataTests: XCTestCase {
    private let now = DemoClock.parse("2026-10-12T09:41:00+08:00")!

    override func setUp() {
        super.setUp()
        L10n.setLanguage(.en)
    }

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    private func report(_ rows: [AgentDescriptor] = DemoData.agents) -> UsageReport {
        DemoUsageProvider.report(agents: rows, historyHours: 169, now: now, stage: nil)
    }

    func testTheWindowsAreNamedAndKeyedAsTheirProvidersBuildThem() {
        let rows = DemoData.claudeRows + DemoData.codexRows
        XCTAssertEqual(rows.map(\.windowKey),
                       ["claude-session", "claude-weekly", "claude-weekly-fable", "codex", "codex:spark:primary", "codex:spark:secondary"])
        XCTAssertEqual(rows.map(\.name), ["Current session", "Weekly limit · All models", "Weekly limit · Fable", "Weekly limit",
                                         "GPT-5.3-Codex-Spark · 5h limit", "GPT-5.3-Codex-Spark · Weekly limit"])
        XCTAssertEqual(rows.map(\.shortName), ["5h", "Weekly", "Fable", "Weekly", "Spark 5h", "Spark 7d"])
        XCTAssertEqual(rows.map(\.allModels), [true, true, false, true, false, false])
        XCTAssertEqual(Set(rows.prefix(3).map(\.account)), [DemoData.claudeAccount])
        XCTAssertEqual(Set(rows.suffix(3).map(\.account)), [DemoData.codexAccount])
        XCTAssertEqual(DemoData.agents.suffix(2).map(\.id), ["deepseek-model:deepseek-v4-pro", "deepseek-model:deepseek-v4-flash"])
        XCTAssertEqual(DemoData.consumers.map(\.name), ["Fable 5.1", "Opus 5.5", "Sonnet 5.5", "Haiku 4.5", "gpt-6-astra", "gpt-6.1-sol",
                                                       "codex-auto-review", "deepseek-v4-pro", "deepseek-v4-flash"])
        XCTAssertEqual(Set(DemoData.everyAgent.map(\.id)).count, DemoData.everyAgent.count)
    }

    /// Codex's provider words its windows in the interface's language when it reads them, so rows saved in one language
    /// come back named in the other.
    func testRowsSavedInOneLanguageAreReportedInTheCurrentOne() {
        let saved = DemoData.agents
        L10n.setLanguage(.zhHans)
        let reported = report(saved).discoveredAgents
        XCTAssertEqual(reported.map(\.id), saved.map(\.id))
        XCTAssertEqual(reported[3].model, "每周额度")
        XCTAssertEqual(reported[4].shortName, "Spark 5h")
        XCTAssertEqual(reported[4].model, "GPT-5.3-Codex-Spark · 5 小时额度")
        let other = AgentDescriptor(id: "newcomer", vendor: "Newcomer", model: "Plan", source: "", enabled: false)
        XCTAssertEqual(report([other]).discoveredAgents, [other], "A row that is not the sample's is reported as given")
    }

    func testEachWindowReadsWhatTheSampleSaysAndForecastsFromItsBurn() throws {
        let report = report(), rows = DemoData.claudeRows + DemoData.codexRows
        XCTAssertEqual(rows.map { report.snapshot(for: $0.id)?.remainingPct }, [88, 21, 40, 51, 82, 76])
        let resets: [TimeInterval?] = rows.map { report.snapshot(for: $0.id)?.resetAt?.timeIntervalSince(now) }
        XCTAssertEqual(resets, [4320, 432_000, 432_000, 518_400, 7200, 518_400])
        XCTAssertEqual(rows.map { report.snapshot(for: $0.id)?.weeklyRemainingPct }, [21, 21, 21, 51, 76, 76],
                       "Each row carries its account's week, a Spark row its bucket's")
        let session = try XCTUnwrap(report.insightsByAgent[rows[0].id]), week = try XCTUnwrap(report.insightsByAgent[rows[1].id])
        XCTAssertEqual(session.burnRatePctPerHour, 6.3)
        XCTAssertEqual(session.weeklyCapHits, 2)
        XCTAssertEqual(session.weeklyWaitTotal, 7740)
        XCTAssertEqual(try XCTUnwrap(week.timeToExhaust), 900 * 60, accuracy: 1, "21% left at 1.4% an hour is fifteen hours")
        XCTAssertNil(report.insightsByAgent[rows[4].id]?.timeToExhaust, "Spark burns nothing")
        XCTAssertNil(report.insightsByAgent[rows[5].id]?.burnRatePctPerHour, "too few readings to tell")
        XCTAssertEqual(report.consumerIdsByQuota[rows[2].id], ["claude-model:claude-fable-5-1"])
        XCTAssertEqual(report.consumerIdsByQuota[rows[3].id]?.count, 3)
        XCTAssertEqual(report.accounts?["Claude"]?.map(\.plan), ["max_20x"])
        XCTAssertEqual(report.accounts?["Codex"]?.first?.resetCredits?.availableCount, 2)
        XCTAssertEqual(report.billing.first?.balances.first?.total, Decimal(string: "8.85"))
        XCTAssertEqual(report.billing.first?.sessionCosts["s8"]?["CNY"], Decimal(string: "0.01239"))

        let codexOnly = self.report([rows[3]])
        XCTAssertEqual(codexOnly.snapshots.map(\.agentId), [rows[3].id], "A report reads the windows among the rows it is given")
        XCTAssertEqual(codexOnly.accounts?.keys.sorted(), ["Codex"])
        XCTAssertTrue(codexOnly.billing.isEmpty)
        XCTAssertEqual(self.report(DemoData.everyAgent).snapshot(for: "cursor")?.remainingPct, 83)
    }

    func testTheSessionsAreTheSamplesNineWithTheFirstTwoRunning() throws {
        let report = report()
        XCTAssertEqual(report.sessions.map(\.id), (1...9).map { "s\($0)" })
        XCTAssertEqual(report.sessions.filter(\.isLive).map(\.id), ["s1", "s2"])
        XCTAssertEqual(report.sessions.map(\.task).prefix(3), ["Build the iOS dashboard", "Review App Store sandbox support", "Refine settings and colors"])
        XCTAssertEqual(Set(report.sessions.map(\.agentId)).subtracting(report.consumers.map(\.id)), [], "Every session's model is a consumer")
        let first = try XCTUnwrap(report.sessions.first), usage = try XCTUnwrap(report.sessionUsage?["s1"])
        XCTAssertEqual(first.pctOfWindow, 6.5)
        XCTAssertEqual(first.client, "Claude Code")
        XCTAssertEqual(first.terminal, "hud-ios")
        XCTAssertEqual(usage.total.kinds.total, 52_232_952)
        XCTAssertEqual(usage.listCost, Decimal(string: "24.72097525"))
        XCTAssertEqual([usage.turnCount, usage.calls, usage.contextTokens, usage.contextWindow], [26, 217, 657_496, 1_000_000])
        XCTAssertEqual(try XCTUnwrap(usage.cacheHitRate), 0.99, accuracy: 0.001)
        XCTAssertEqual(usage.models.map(\.agentId), ["claude-model:claude-fable-5-1", "claude-model:claude-haiku-4-5"])
        XCTAssertEqual([first.tokensIn, first.tokensOut, first.cacheReadTokens], [467_602, 74_130, 45_658_333], "its own model's, without the sub-agent's")

        let costs = try (2...9).map { try XCTUnwrap(report.sessionUsage?["s\($0)"]).listCost }
        XCTAssertEqual(costs, ["23.150842", "6.4767801", "0.9336431", "8.6971268", "6.4912077", "0.4950673", nil, "0.8533943"].map { $0.flatMap { Decimal(string: $0) } })
        let billed = try XCTUnwrap(report.sessionUsage?["s8"])
        XCTAssertEqual(billed.costs, ["CNY": Decimal(string: "0.01239")!, "USD": Decimal(string: "0.0017")!])
        XCTAssertNil(billed.contextWindow)
        XCTAssertTrue(billed.turns.allSatisfy { $0.listCost == nil }, "DeepSeek's session is billed, not list-priced")
        let lapsed = try XCTUnwrap(report.sessionUsage?["s5"]?.turns[11])
        XCTAssertNotNil(lapsed.recachedTokens, "the twelfth turn of s5 came back after its cache lapsed")
    }

    func testATurnsCallsAddUpToTheTurn() throws {
        let usage = DemoData.sessionUsage(now: now)
        for plan in DemoData.plans {
            for (index, turn) in try XCTUnwrap(usage[plan.id]).turns.enumerated() {
                let calls = DemoData.turnCalls(session: plan.id, turn: turn)
                XCTAssertEqual(calls.count, turn.calls, "\(plan.id) turn \(index)")
                XCTAssertEqual(calls.reduce(SessionUsage.Tokens()) { $0 + $1.tokens }, turn.tokens, "\(plan.id) turn \(index)")
                XCTAssertEqual(calls.filter { !$0.own }.reduce(SessionUsage.Tokens()) { $0 + $1.tokens }, turn.subagents ?? .init(), "\(plan.id) turn \(index)")
                if let cost = turn.listCost {
                    XCTAssertEqual(calls.reduce(Decimal(0)) { $0 + ($1.listCost ?? 0) }, cost, "\(plan.id) turn \(index)")
                }
                XCTAssertEqual(calls.last { $0.own }?.context, turn.contextTokens, "\(plan.id) turn \(index)")
                XCTAssertTrue(calls.allSatisfy { $0.timestamp >= turn.start && $0.timestamp <= turn.end.addingTimeInterval(2) })
            }
        }
    }

    func testAMonthOfTokensIsFifteenMillionADayAcrossTheSamplesModels() {
        let usage = DemoData.usage(now: now)
        func total(_ hours: Double, _ model: String? = nil) -> Int {
            usage.filter { $0.start >= now.addingTimeInterval(-hours * 3600) && (model == nil || $0.agentId.hasSuffix(":" + model!)) }
                .reduce(0) { $0 + $1.tokensIn + $1.tokensOut }
        }
        XCTAssertEqual(usage.last?.start, now.addingTimeInterval(-26 * 60), "the last whole quarter hour before 09:41")
        XCTAssertEqual(usage.map(\.start).min(), now.addingTimeInterval(-26 * 60 - 2879 * 900))
        // One whole day of quarter hours, which the day that ended at the last bucket holds.
        let day = usage.filter { $0.start >= now.addingTimeInterval(-26 * 60 - 95 * 900) }.reduce(0) { $0 + $1.tokensIn + $1.tokensOut }
        XCTAssertEqual(day, 14_999_908)
        XCTAssertEqual(total(24), 14_672_040, "the 95 quarter hours that began in the last 24 hours")
        XCTAssertEqual([total(24, "claude-opus-5-5"), total(24, "claude-fable-5-1"), total(24, "codex-auto-review"), total(24, "gpt-6.1-sol"),
                        total(24, "deepseek-v4-flash"), total(24, "claude-sonnet-5-5")],
                       [6_186_450, 4_972_986, 2_419_720, 491_800, 314_204, 286_880])
        XCTAssertEqual(total(720), 449_669_372)
        XCTAssertEqual(Set(usage.map(\.agentId)).subtracting(DemoData.consumers.map(\.id)), [])
    }
}
