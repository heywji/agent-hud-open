import AppKit
import AgentHUDCore
import SwiftUI

/// Owns the local desktop presentation — the HUD on every screen and its Settings window — and observes the supplied
/// usage store.
@MainActor
public final class DesktopApplication {
    public let settings: SettingsStore
    public let store: UsageStore
    private let options: DesktopLaunchOptions
    /// The clients whose observer directory existed at the last look, so one that appears later is noticed.
    private var observedClients: Set<String> = []
    private var notch: IslandController?
    private lazy var settingsWindow = SettingsWindowController(settings: settings, store: store)

    public init(options: DesktopLaunchOptions, settings: SettingsStore, store: UsageStore) {
        self.options = options
        self.settings = settings
        self.store = store
    }

    public func start() {
        let sources = SourceDetector.resolve(SourceDetector.detect(), report: store.report)
        settings.update { $0.applyLiveStatusDefaults(sources: sources) }
        applyAppearance()
        let notch = IslandController(store: store, settings: settings)
        notch.onOpenSettings = { [weak self] in self?.showSettings() }
        self.notch = notch
        trackChanges({ [weak self] in
            self?.settings.settings.appearance
        }, onChange: { [weak self] in self?.applyAppearance() })
        trackChanges({ [weak self] in
            self?.settings.settings.language
        }, onChange: { [weak self] in
            guard let self else { return }
            self.notch?.apply(animated: false)
            Task { await self.store.refresh() }
        })
        trackChanges({ [weak self] in
            _ = self?.store.lastError
        }, onChange: { [weak self] in
            if let error = self?.store.lastError { NSLog("[AgentHUD] refresh failed: %@", error) }
        })
        // A new install starts with launch at login on, and nothing registers it until the setting is applied: a start
        // registers an item that was never registered, and a flip of the switch applies at once.
        if settings.settings.launchAtLogin { LoginItem.registerIfNeverRegistered() }
        trackChanges({ [weak self] in
            self?.settings.settings.launchAtLogin
        }, onChange: { [weak self] in
            guard let self else { return }
            LoginItem.set(self.settings.settings.launchAtLogin)
        })
        // The host installs the handlers at launch; a change of mind while running applies at once, with the same
        // executable the host gave them.
        trackChanges({ [weak self] in
            self?.settings.settings.clientHooks
        }, onChange: { [weak self] in
            guard let self, let executable = Bundle.main.executableURL else { return }
            SessionObservers.configure(executable: executable, enabled: self.settings.settings.clientHooks)
        })
        // A client run for the first time creates its directory, and its observer goes in with the next report
        // rather than at the next launch.
        observedClients = SessionObservers.observedClients()
        trackChanges({ [weak self] in
            _ = self?.store.report
        }, onChange: { [weak self] in self?.installObserversForNewClients() })
        store.start()
        if options.openPanel { notch.forceOpen() }
        if options.showSettings { showSettings() }
    }

    public func stop() {
        store.stop()
    }

    public func showSettings(pageID: String? = nil) { settingsWindow.show(pageID: pageID) }

    /// Start-up installs observers only where a client's directory already exists. A client that already runs loads its
    /// observer when it next starts or reloads.
    private func installObserversForNewClients() {
        let present = SessionObservers.observedClients()
        if settings.settings.clientHooks, !present.subtracting(observedClients).isEmpty { SessionObservers.installObservers() }
        observedClients = present
    }

    private func applyAppearance() {
        switch settings.settings.appearance {
        case .system: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }
}
