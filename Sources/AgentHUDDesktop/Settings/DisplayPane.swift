import AppKit
import SwiftUI
import AgentHUDCore

struct DisplayPane: View {
    let settings: SettingsStore
    let store: UsageStore
    let theme: Theme
    /// Which display the screen settings are editing.
    @State private var screen: String = ScreensPane.attached().first?.key ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ScreensPane(settings: settings, store: store, theme: theme, selected: $screen)
            IslandPane(settings: settings, theme: theme)
        }
    }
}
