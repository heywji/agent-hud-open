import AppKit
import AgentHUDCore
import AgentHUDDesktop

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var desktop: DesktopApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = DesktopLaunchOptions.parse(CommandLine.arguments)
        // Only one Agent HUD runs at a time, since the one that runs points the clients' hooks at itself: a launch while
        // another copy runs says where it is and quits before reading or writing anything. A probe reads and quits, so it
        // may run beside the real one, unless it is told to reset the preferences, which that one uses.
        if options.resetDefaults || !options.probe, !SingleInstance.claim() {
            NSApp.terminate(nil)
            return
        }
        if options.resetDefaults, let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        let settings = UsageAssembly.settings(language: options.language)
        if options.probe {
            Task { @MainActor in exit(await UsageProbe.run(settings: settings)) }
            return
        }
        let store = UsageAssembly.store(settings: settings, ledger: .open())
        if let executable = Bundle.main.executableURL {
            SessionObservers.configure(executable: executable, enabled: settings.settings.clientHooks)
        }
        let desktop = DesktopApplication(options: options, settings: settings, store: store)
        self.desktop = desktop
        desktop.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { desktop?.stop() }
}

// Hooks and adapter commands run as short-lived processes, without the interface or an account query.
if let status = HookEntry.handle(arguments: CommandLine.arguments) { exit(status) }

if CommandLine.arguments.contains("--probe-open-agents") {
    Task { print(await OpenAgentDiagnostics.localSummary()); exit(0) }
    dispatchMain()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
