import AppKit
import AgentHUDCore

@MainActor
final class SettingsWindowController: HostedWindowController {
    private let navigation = SettingsNavigation()
    private let pageIDs = Set(SettingsTab.allCases.map(\.id))

    init(settings: SettingsStore, store: UsageStore) {
        super.init(size: SettingsWindowLayout.size, title: Self.title, resizable: true)
        // Custom controls handle their own drags; only the title bar should move this window.
        window?.isMovableByWindowBackground = false
        window?.minSize = SettingsWindowLayout.minimum
        setContent(SettingsView(settings: settings, store: store, navigation: navigation))
    }

    private static var title: String { AppResources.applicationName + L10n.text(" 设置", " Settings") }

    override func show() {
        show(pageID: nil)
    }

    func show(pageID: String?) {
        if let pageID, pageIDs.contains(pageID) { navigation.pageID = pageID }
        window?.title = Self.title
        super.show()
    }

}
