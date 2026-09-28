import XCTest
@testable import AgentHUDCore

final class GrokQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func integer(_ number: UInt8, _ value: UInt64) -> [UInt8] {
        var value = value, result = [number << 3]
        repeat {
            var byte = UInt8(value & 127); value >>= 7
            if value > 0 { byte |= 128 }
            result.append(byte)
        } while value > 0
        return result
    }

    private func message(_ number: UInt8, _ bytes: [UInt8]) -> [UInt8] {
        Array(integer(0, UInt64(number) << 3 | 2).dropFirst()) + Array(integer(0, UInt64(bytes.count)).dropFirst()) + bytes
    }

    private func percent(_ value: Float) -> [UInt8] {
        [13] + (0..<4).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) }
    }

    private func response(percent value: Float? = nil, start: UInt64 = 1_799_999_900, end: UInt64 = 1_800_604_700,
                          kind: UInt64 = 1, extra: [UInt8] = []) -> Data {
        let period = integer(1, kind) + message(2, integer(1, start)) + message(3, integer(1, end))
        return Data(message(1, (value.map(percent) ?? []) + message(8, period) + extra))
    }

    private func frame(_ data: Data, flag: UInt8 = 0) -> Data {
        Data([flag] + (0..<4).reversed().map { UInt8(truncatingIfNeeded: data.count >> ($0 * 8)) }) + data
    }

    func testPublishedPercentAndActiveProtoZero() throws {
        XCTAssertEqual(try GrokCreditsWire.parse(response(percent: 42.5), now: now).used, 42.5)
        let zero = try GrokCreditsWire.parse(frame(response()) + frame(Data("grpc-status: 0\r\n".utf8), flag: 128), now: now)
        XCTAssertEqual(zero.used, 0)
        XCTAssertEqual(zero.duration, 604800)
        XCTAssertEqual(zero.periodType, "USAGE_PERIOD_TYPE_WEEKLY")
        // Unknown length-delimited fields are opaque, not guessed to be messages.
        XCTAssertEqual(try GrokCreditsWire.parse(response(extra: message(20, [255])), now: now).used, 0)
    }

    func testMissingJsonUsageRemainsUnknownAndInvalidWireCannotConfirmZero() throws {
        let json = try ProviderJSON.read(Data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2027-01-15T08:00:00Z","end":"2027-01-22T08:00:00Z"}}}"#.utf8))
        XCTAssertTrue(try GrokClient.parse(json).windows.isEmpty)
        for data in [response(start: 1_800_000_001), response(end: 1_799_999_999), response(kind: 99),
                     response(percent: .nan), response(percent: -1), response(percent: 101),
                     response(percent: 20, extra: percent(10)), response(extra: [0]), response(extra: [128]),
                     Data(response().dropLast()), frame(response(), flag: 1), frame(response()) + Data([0]),
                     frame(response()) + frame(Data("grpc-status: 16\r\n".utf8), flag: 128),
                     response(extra: message(7, [21, 0, 0, 0, 0]))] {
            XCTAssertThrowsError(try GrokCreditsWire.parse(data, now: now))
        }
    }

    func testUnknownProxyFetchUsesSameTokenAndKeepsProxyReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"https://auth.x.ai::cli":{"key":"fixture-token","user_id":"fixture-user","expires_at":"2030-01-01T00:00:00Z"}}"#.utf8).write(to: root.appendingPathComponent("auth.json"))
        let wire = response(start: UInt64(Date().timeIntervalSince1970) - 100, end: UInt64(Date().timeIntervalSince1970) + 604700)
        let client = GrokClient(home: root, http: ProviderHTTP(send: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            switch request.url?.path {
            case "/v1/billing": return Data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-28T08:07:13Z","end":"2026-10-05T08:07:13Z"}}}"#.utf8)
            case "/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.httpBody, Data([0, 0, 0, 0, 2, 8, 0]))
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                XCTAssertEqual(request.timeoutInterval, 6)
                return wire
            default: return Data(#"{"subscription_tier_display":"SuperGrok"}"#.utf8)
            }
        }))
        let quota = try await client.fetch()
        XCTAssertEqual(quota.windows.first?.remaining, 100)
        XCTAssertEqual(quota.windows.first?.reset, DateParsing.internet("2026-10-05T08:07:13Z"))
        XCTAssertEqual(quota.windows.first?.duration, 604800)
        XCTAssertNil(quota.displayNotice)
        XCTAssertEqual(quota.plan, "SuperGrok")
        let failed = GrokClient(home: root, http: ProviderHTTP(send: { request in
            if request.url?.path == "/v1/billing" {
                return Data(#"{"config":{"currentPeriod":{"end":"2026-10-05T08:07:13Z"}}}"#.utf8)
            }
            throw ProviderHTTPError(status: 503)
        }))
        let unknown = try await failed.fetch()
        XCTAssertTrue(unknown.windows.isEmpty, "A failed retry must not manufacture a zero percentage")
        XCTAssertNotNil(unknown.displayNotice)
        let explicit = GrokClient(home: root, http: ProviderHTTP(send: { request in
            XCTAssertNotEqual(request.httpMethod, "POST", "Published usage does not need a fallback request")
            return Data(#"{"config":{"creditUsagePercent":12.5}}"#.utf8)
        }))
        let published = try await explicit.fetch()
        XCTAssertEqual(published.windows.first?.remaining, 87.5)
    }

    @MainActor
    func testExpiredQuotaShowsNoLevelOrForecast() {
        let agent = AgentDescriptor(id: "grok", vendor: "Grok", model: "Weekly", source: "", enabled: true)
        let report = UsageReport(generatedAt: now, snapshots: [.init(agentId: agent.id, remainingPct: 0,
            resetAt: now.addingTimeInterval(-1), updatedAt: now.addingTimeInterval(-86400))], sessions: [], discoveredAgents: [agent])
        let defaults = UserDefaults(suiteName: "GrokQuotaTests.\(UUID().uuidString)")!
        let store = UsageStore(provider: DemoUsageProvider(), settings: SettingsStore(defaults: defaults, defaultAgents: [agent]))
        store.replace(report: report)
        store.now = now
        let row = store.rows.first { $0.id == agent.id }
        XCTAssertNotNil(row)
        XCTAssertNil(row?.level, "a passed reset takes the window out of the glow and alerts")
        XCTAssertNil(store.quotaForecastHint(for: agent.id))
        XCTAssertEqual(row?.resetLabel(now: now), L10n.text("等待更新", "Pending update"))
        XCTAssertNil(store.maxUsedPct)
    }

    @MainActor
    func testTranscriptWarningDoesNotMarkConfirmedZeroQuotaUnavailable() throws {
        let account = ProviderAccount.unresolved(provider: "Grok", home: "fixture")
        let agent = AgentDescriptor(id: account.windowID("grok"), vendor: "Grok", model: "Weekly", source: "",
                                    enabled: true, account: account)
        let snapshot = UsageSnapshot(agentId: agent.id, remainingPct: 100, resetAt: now.addingTimeInterval(604800),
                                     windowDuration: 604800, updatedAt: now)
        func report(quotaNotice: String? = nil) -> UsageReport {
            UsageReport(generatedAt: now, snapshots: [snapshot], sessions: [], discoveredAgents: [agent],
                        sourceNotices: ["Grok": "Older sessions only report context size"], readingIssues: [:],
                        accounts: ["Grok": [AccountObservation(account: account, observedAt: now, quotaNotice: quotaNotice,
                                                               readingIssue: quotaNotice.map(ReadingIssue.readFailed))]])
        }
        let defaults = UserDefaults(suiteName: "GrokQuotaTests.\(UUID().uuidString)")!
        let store = UsageStore(provider: DemoUsageProvider(), settings: SettingsStore(defaults: defaults, defaultAgents: [agent]))
        store.replace(report: report())
        store.now = now
        XCTAssertNil(store.report?.quotaNotice(for: agent))
        XCTAssertEqual(store.rows.first?.usedPct, 0)
        XCTAssertEqual(store.rows.first?.level, .ok, "Transcript warnings must not grey out valid quota")
        XCTAssertEqual(store.quotaForecastHint(for: agent.id), L10n.text("额度充足 · 已用 0%", "Quota available · 0% used"))

        store.replace(report: report(quotaNotice: "Billing unavailable"))
        store.now = now
        XCTAssertEqual(store.report?.quotaNotice(for: agent), "Billing unavailable")
        XCTAssertNil(store.rows.first?.level, "Real quota errors still suppress the healthy state")
        XCTAssertNil(store.quotaForecastHint(for: agent.id))
        let legacy = UsageReport(generatedAt: now, snapshots: [snapshot], sessions: [], discoveredAgents: [agent],
                                 sourceNotices: ["Grok": "Billing unavailable"])
        XCTAssertEqual(legacy.quotaNotice(for: agent), "Billing unavailable", "Unscoped legacy errors remain supported")
    }
}
