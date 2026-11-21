import Foundation
import AgentHUDCore

/// Command-line switches used for development and manual checks.
public struct DesktopLaunchOptions: Equatable {
    /// `--open-panel`: start with the panel expanded.
    public var openPanel = false
    /// `--show-settings`: open the settings window at launch.
    public var showSettings = false
    /// `--reset-defaults`: wipe stored settings before starting.
    public var resetDefaults = false
    /// `--probe`: run one real fetch, print a summary, quit (diagnostics).
    public var probe = false
    /// `--lang zh|en`: force the UI language for this launch (manual checks).
    public var language: AppLanguage?

    public init() {}

    public static func parse(_ arguments: [String]) -> DesktopLaunchOptions {
        var options = DesktopLaunchOptions()
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--open-panel": options.openPanel = true
            case "--show-settings": options.showSettings = true
            case "--reset-defaults": options.resetDefaults = true
            case "--probe": options.probe = true
            case "--lang": options.language = iterator.next().flatMap(Self.language(from:))
            default: break
            }
        }
        return options
    }

    private static func language(from value: String) -> AppLanguage? {
        switch value.lowercased() {
        case "zh", "zh-hans", "cn": return .zhHans
        case "en": return .en
        case "system": return .system
        default: return nil
        }
    }
}
