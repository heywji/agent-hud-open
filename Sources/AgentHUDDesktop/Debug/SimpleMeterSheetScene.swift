import SwiftUI
import AgentHUDCore

/// A contact sheet of the Simple panel: rings and numbers on and off at several sizes and strokes, along the
/// top edge and down a side, to check the panel without driving the HUD.
struct SimpleMeterSheetScene: View {
    private static let items = [
        SimpleMeterItem(vendor: "Claude", usedPct: 62, level: .ok),
        SimpleMeterItem(vendor: "Codex", usedPct: 18, level: .ok),
        SimpleMeterItem(vendor: "Cursor", usedPct: 84, level: .warning),
        SimpleMeterItem(vendor: "DeepSeek", usedPct: 100, level: .critical),
        SimpleMeterItem(vendor: "Kimi", usedPct: nil, level: nil),
    ]
    /// Rings and numbers, rings alone, numbers alone, marks alone.
    private static let variants: [(rings: Bool, numbers: Bool)] = [(true, true), (true, false), (false, true), (false, false)]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach([16.0, 22, 30, 40], id: \.self) { size in
                row { variant in panel(size: size, ring: 1.5, variant, edge: .top) }
            }
            HStack(alignment: .top, spacing: 28) {
                ForEach([1.0, 1.5, 2.5, 4], id: \.self) { ring in panel(size: 22, ring: ring, Self.variants[0], edge: .top) }
            }
            row { variant in panel(size: 22, ring: 1.5, variant, edge: .right) }
        }
        .padding(28)
        .background(LinearGradient(colors: [Color(red: 0.13, green: 0.17, blue: 0.27), Color(red: 0.55, green: 0.47, blue: 0.4)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func row(@ViewBuilder _ cell: @escaping ((rings: Bool, numbers: Bool)) -> some View) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ForEach(Array(Self.variants.enumerated()), id: \.offset) { cell($0.element) }
        }
    }

    private func panel(size: Double, ring: Double, _ variant: (rings: Bool, numbers: Bool), edge: HUDEdge) -> some View {
        let config = SimpleMeterConfig(items: Self.items, placement: ScreenPlacement(
            mode: .simple, edge: edge, simpleSize: size, ringWidth: ring,
            showsRings: variant.rings, showsNumbers: variant.numbers))
        return SimpleMeterView(config: config)
            .frame(width: config.stripSize.width, height: config.stripSize.height)
    }
}
