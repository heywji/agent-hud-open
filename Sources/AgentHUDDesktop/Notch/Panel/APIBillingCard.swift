import SwiftUI
import AgentHUDCore

/// An API-funded account in the panel: its balance and what the last day cost, in money, with no percentage quota or
/// reset period.
struct APIBillingCard: View {
    let billing: APIBilling
    let store: UsageStore
    let theme: Theme

    /// The day the estimated cost covers, the same day the panel's token chart shows.
    static let costRange = StatsRange.hours24

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AgentLogo(vendor: billing.vendor, size: 14)
                    .frame(width: IslandRowLayout.inset * 2 + IslandRowLayout.markerWidth)
                Text(billing.displayName)
                    .font(IslandRowLayout.headingFont)
                    .foregroundStyle(theme.text)
                Spacer()
            }
            .padding(.vertical, IslandRowLayout.headingVerticalPadding)
            // A balance whose read failed keeps its last amount without a colour, and says why.
            if let reason = store.view.assessment(of: billing).status.reason {
                Text(reason)
                    .font(.ui(11))
                    .foregroundStyle(theme.statusText(.warning))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, IslandRowLayout.textInset)
            }
            if billing.balances.isEmpty {
                balanceLine(currency: billing.currency, balance: nil)
            } else {
                ForEach(billing.balances) { balance in
                    balanceLine(currency: balance.currency, balance: balance)
                }
            }
        }
    }

    private func balanceLine(currency: String, balance: AccountBalance?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("账户余额", "Account balance")).font(.ui(11)).foregroundStyle(theme.secondary)
                Text(balance.map { MoneyFormat.amount($0.total, currency: currency) } ?? "—")
                    .font(.tabular(15, .semibold))
                    .foregroundStyle(balance.flatMap { store.balanceLevel($0, billing: billing) }.map { theme.statusText($0) } ?? theme.text)
                    .help(billing.isAvailable == false ? L10n.text("余额不足，API 暂不可用", "Insufficient balance; API unavailable") : L10n.text("来自 DeepSeek 官方余额接口", "From the official DeepSeek balance API"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("费用估算 · ", "Est. cost · ") + Self.costRange.recentLabel)
                    .font(.ui(11)).foregroundStyle(theme.secondary)
                Text(billing.estimatedCost(currency: currency, during: Self.costRange.interval(endingAt: store.dataDate))
                    .map { MoneyFormat.amount($0, currency: currency, estimated: true) } ?? L10n.text("暂无价格", "Unpriced"))
                    .font(.tabular(15, .semibold))
                    .foregroundStyle(theme.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, IslandRowLayout.textInset)
        .padding(.trailing, IslandRowLayout.inset)
    }
}
