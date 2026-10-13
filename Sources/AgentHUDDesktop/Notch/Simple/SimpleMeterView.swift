import SwiftUI
import AgentHUDCore

/// The collapsed HUD on a screen in Simple mode: a small floating panel with no glow behind it. Each agent
/// is its mark, with its tightest window drawn as a ring round the mark, written as a percentage beside it,
/// or both. The ring and the number take the window's level colour. Nothing moves unless the panel's bots are
/// switched on: a working agent's mark is then its bot, and an idle one visits as a bot now and then.
struct SimpleMeterView: View {
    let config: SimpleMeterConfig
    /// The island draws the panel behind the figures, so that the same frame can grow into the usage panel.
    /// Left off, the view draws its own fill and hairline, as a preview with no island does.
    var onIsland = false
    /// How dark the panel is; whatever grows out of it is filled the same.
    static let fillOpacity = 0.82

    var body: some View {
        let panel = config.panelSize
        let insets = config.insets
        let shape = RoundedRectangle(cornerRadius: config.cornerRadius, style: .continuous)
        let layout = config.edge.isHorizontal
            ? AnyLayout(HStackLayout(spacing: config.itemGap))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: config.itemGap))
        layout {
            ForEach(config.items) { cell($0) }
        }
        .padding(EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right))
        .frame(width: panel.width, height: panel.height, alignment: .leading)
        .background {
            shape.fill(.black.opacity(Self.fillOpacity))
                .overlay { shape.strokeBorder(.white.opacity(0.14), lineWidth: 1) }
                .opacity(onIsland ? 0 : 1)
        }
        .padding(margin, SimpleMeterConfig.edgeMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    private func cell(_ item: SimpleMeterItem) -> some View {
        let tint = item.level.map { Color(StatusPalette.color(for: $0)) } ?? Color(StatusPalette.idle)
        return HStack(spacing: config.labelSpacing) {
            ZStack {
                if config.showsRings {
                    Circle().strokeBorder(.white.opacity(0.14), lineWidth: config.ringWidth)
                    Circle().inset(by: config.ringWidth / 2)
                        .trim(from: 0, to: min(1, max(0, (item.usedPct ?? 0) / 100)))
                        .stroke(tint, style: StrokeStyle(lineWidth: config.ringWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                if config.bots {
                    // The panel has its own switch, so it does not follow the one for dock marks and reminders.
                    BotMark(vendor: item.vendor, size: config.logo, phase: item.attention.phase(working: item.isWorking), staysBot: false)
                        .environment(\.botLogos, true)
                } else {
                    AgentLogo(vendor: item.vendor, size: config.logo)
                }
            }
            .frame(width: config.mark, height: config.mark)
            if config.showsNumbers {
                Text(item.label)
                    .font(.tabular(config.fontSize, .regular))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: config.edge.isHorizontal ? config.labelWidth(item) : config.labelColumn, alignment: .trailing)
            }
        }
        .accessibilityLabel("\(item.vendor) \(item.label)")
    }

    /// The side the margin is on, and the corner the panel is held to: against its edge, centred along it.
    private var margin: Edge.Set {
        switch config.edge {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    private var alignment: Alignment {
        switch config.edge {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }
}
