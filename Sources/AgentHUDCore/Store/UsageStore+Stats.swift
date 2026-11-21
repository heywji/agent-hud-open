import Foundation

/// The panel's token history: who spends the tokens, and the last day of them in quarter-hour columns.
@MainActor
public extension UsageStore {
    /// Token spenders (model families). Token spend is independent of which remaining-quota windows the user monitors.
    var consumers: [AgentDescriptor] { report?.consumers ?? [] }

    /// The latest 96 ledger quarters, including the quarter containing this reading.
    var hudTokenInterval: DateInterval {
        let quarter = TokenBucketSize.minutes15.duration
        let end = Date(timeIntervalSince1970: ceil(dataDate.timeIntervalSince1970 / quarter) * quarter)
        return DateInterval(start: end.addingTimeInterval(-24 * 3600), end: end)
    }

    /// Every consumer's tokens of every recorded kind in each quarter of `hudTokenInterval`.
    var hudTokenColumns: [TokenColumn] {
        ChartData.tokenBars(usage: report?.usage ?? [], agentIds: consumers.map(\.id), interval: hudTokenInterval,
                            bucketSize: .minutes15, dimensions: .all)
    }

    /// Quota switches do not change token-chart colors.
    func consumerPaletteIndex(_ id: String) -> Int {
        consumers.firstIndex { $0.id == id } ?? 0
    }
}
