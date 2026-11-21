import AppKit
import SwiftUI
import AgentHUDCore

/// Reports the panel's natural height so the island window can size itself to the content.
struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

/// The dot a session wears in the panel: blocked on the user, running, or neither.
enum SessionDot: Equatable {
    case waiting, running, ended

    init(_ phase: SessionPhase) {
        switch phase.state {
        case .waitingForApproval: self = .waiting
        case .running: self = .running
        case .idle, .unverified: self = .ended
        }
    }
}

/// The board: the selected quota rows and balances, a compact token chart, then the local session summary.
struct HoverPanelView: View {
    let store: UsageStore
    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = { NSApp.terminate(nil) }
    /// Nil measures the natural layout; the visible panel gives its bounded height.
    var height: CGFloat? = nil
    /// The notch keeps its hardware clearance; a dock leaves room beside its parked logo strip instead.
    var insets = HoverPanelView.notchInsets
    static let notchInsets = EdgeInsets(top: 32, leading: 18, bottom: 14, trailing: 18)

    private let theme = Theme.island
    private let spacing: CGFloat = 10

    private var showsQuota: Bool { store.settings.settings.showIslandQuota }
    private var showsTokens: Bool {
        store.settings.settings.showIslandTokens && (store.isLoading || store.isIndexing || !store.consumers.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if height != nil {
                ScrollView(.vertical) { measuredContent }
            } else {
                measuredContent
            }
            footer
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PanelHeightKey.self,
                                           value: proxy.size.height + insets.top + insets.bottom + spacing)
                })
        }
        .padding(insets)
        .frame(height: height, alignment: .top)
        .foregroundStyle(theme.text)
    }

    private var measuredContent: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
            })
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let error = store.lastError {
                Text(L10n.text("刷新失败：", "Refresh failed: ") + error)
                    .font(.ui(11)).foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsQuota, !store.rowGroups.isEmpty {
                quotaBlock
            }
            if showsQuota {
                ForEach(store.enabledBilling) { billing in
                    APIBillingCard(billing: billing, store: store, theme: theme)
                        .padding(.top, 8)
                        .topDivider(theme.divider)
                }
            }
            if showsTokens {
                TokenConsumptionChart(store: store, theme: theme)
                    .padding(.top, 8)
                    .topDivider(theme.divider)
            }
            if store.settings.settings.showIslandSessions {
                sessionLine
            }
        }
    }

    private var quotaBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(store.rowGroups.enumerated()), id: \.element.vendor) { index, group in
                ProviderQuotaBlock(store: store, vendor: group.vendor, rows: group.rows)
                .padding(.top, index > 0 ? 8 : 0)
                .topDivider(index > 0 ? theme.divider : .clear)
            }
            if store.rows.isEmpty {
                Text(L10n.text("暂无额度数据", "No quota data yet"))
                    .font(.ui(12))
                    .foregroundStyle(theme.secondary)
            }
        }
    }

    /// What is waiting, running and recently ended: the sessions with work in flight first — those waiting for the
    /// user ahead of those still running — then those last active in the past day, up to five rows in total. The
    /// remaining count includes every other session in that summary.
    private var sessionLine: some View {
        let rows = Self.sessionRows(store)
        let running = rows.running, shown = rows.shown
        let hasAbove = store.lastError != nil
            || (showsQuota && (!store.rowGroups.isEmpty || !store.enabledBilling.isEmpty))
            || showsTokens
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.text("会话", "Sessions"))
                    .font(.ui(13, .semibold)).foregroundStyle(theme.text)
                Spacer()
                Text(running.isEmpty
                     ? L10n.text("最近结束", "Recently ended")
                     : L10n.text("\(running.count) 个运行中", "\(running.count) running"))
                    .font(.tabular(12)).foregroundStyle(theme.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("island-sessions")
            if shown.isEmpty {
                Text(L10n.text("还没有会话", "No sessions yet"))
                    .foregroundStyle(theme.secondary)
            } else {
                ForEach(shown) { session in
                    sessionRow(session)
                }
                if rows.more > 0 {
                    Text(L10n.text("还有 \(rows.more) 个", "+\(rows.more) more"))
                        .foregroundStyle(theme.secondary)
                }
            }
        }
        .font(.ui(12))
        .padding(.top, hasAbove ? 8 : 0)
        .topDivider(hasAbove ? theme.divider : .clear)
    }

    private func sessionRow(_ session: LiveSession) -> some View {
        let tokens = "\(TokenFormat.short(session.tokensIn + session.tokensOut + session.cacheReadTokens)) tok"
        let dot = Self.sessionDot(session, store: store)
        return HStack(spacing: 8) {
            sessionMark(session, dot: dot)
            Text(Self.sessionTitle(session))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(tokens)
                .fixedSize()
        }
        .foregroundStyle(theme.secondary)
        .help(session.task)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("island-session-\(session.id)")
    }

    /// The agent's mark with the session's state on its corner: its own colour while it runs, the warning colour
    /// while it waits for the user, grey once it ends. A source without a bundled mark falls back to the dot alone.
    private func sessionMark(_ session: LiveSession, dot: SessionDot) -> some View {
        let color = dotColor(dot, session: session)
        guard let vendor = store.sessionSource(session).agentVendor, !vendor.isEmpty else {
            return AnyView(Circle().fill(color).frame(width: 6, height: 6))
        }
        return AnyView(
            ZStack(alignment: .bottomTrailing) {
                AgentLogo(vendor: vendor, size: 14)
                Circle().fill(color)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(theme.windowBackground, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
            .frame(width: 14, height: 14)
            .opacity(dot == .ended ? 0.7 : 1)
        )
    }

    /// The panel's summary: local work in flight and sessions last active in the past day, with waiting before
    /// running, newest created first, then the most recently ended.
    static func sessionRows(_ store: UsageStore) -> (running: [LiveSession], shown: [LiveSession], more: Int) {
        // Account-wide API receipts belong to the account, not this Mac's local activity summary.
        let view = store.view, cutoff = view.now.addingTimeInterval(-sessionRecency)
        let candidates = view.sessions.filter {
            !$0.session.accountWide && ($0.phase.isInFlight || $0.lastEventAt >= cutoff)
        }
        let active = candidates.filter(\.phase.isInFlight).sorted {
            let lhsWaiting = $0.phase.state == .waitingForApproval
            let rhsWaiting = $1.phase.state == .waitingForApproval
            if lhsWaiting != rhsWaiting { return lhsWaiting }
            return $0.session.startedAt > $1.session.startedAt
        }
        // ReportView already orders by the last event, so ended rows reflect recent work rather than creation.
        let ended = candidates.filter { !$0.phase.isInFlight }
        let summary = active + ended
        let shown = summary.prefix(sessionRowLimit).map(\.session)
        return (active.map(\.session), shown, summary.count - shown.count)
    }

    /// A running session wears its agent's colour, one blocked on the user the warning colour, and an ended one grey.
    static func sessionDot(_ session: LiveSession, store: UsageStore) -> SessionDot {
        SessionDot(store.view.phase(of: session))
    }

    private func dotColor(_ dot: SessionDot, session: LiveSession) -> Color {
        switch dot {
        case .waiting: return theme.status(.warning)
        case .running: return AgentPalette.swiftUIColor(index: store.consumerPaletteIndex(session.agentId))
        case .ended: return theme.dotEnded
        }
    }

    private var footer: some View {
        HStack {
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .help(L10n.text("设置", "Settings"))
            .accessibilityLabel(L10n.text("设置", "Settings"))
            Spacer()
            Button(action: onQuit) {
                Image(systemName: "power")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .help(L10n.text("退出 Agent HUD", "Quit Agent HUD"))
            .accessibilityLabel(L10n.text("退出 Agent HUD", "Quit Agent HUD"))
        }
        .buttonStyle(.plain)
        .font(.ui(14))
        .foregroundStyle(theme.secondary)
        .padding(.top, 6)
        .overlay(alignment: .top) { Rectangle().fill(theme.divider).frame(height: 1) }
    }

    static let sessionRowLimit = 5
    static let sessionRecency: TimeInterval = 24 * 3600

    static func sessionTitle(_ session: LiveSession) -> String {
        guard let terminal = session.terminal, !terminal.isEmpty else { return session.task }
        return "\(shortTask(session.task)) · \(terminal)"
    }

    /// "fix auth bug in middleware" → "fix auth bug"
    static func shortTask(_ task: String) -> String {
        let words = task.split(separator: " ")
        if words.count > 3 { return words.prefix(3).joined(separator: " ") }
        return String(task.prefix(14))
    }
}
