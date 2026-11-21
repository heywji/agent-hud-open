import AgentHUDSupport
import Foundation

/// Handlers that fuller builds of Agent HUD install for features this build leaves out: answering a client's permission
/// requests (`--permission-hook`) and finding a session's terminal again (`--session-origin-hook`).
///
/// A client whose settings still name one of them gets, at once, the answer that leaves it exactly as it would be with no
/// hook (`reply(to:)`), so a stale handler never starts the application. Every start takes the handlers that run this copy
/// back out of the clients' settings (`remove(executable:home:)`); one pointing at another program, or at another copy,
/// is left alone.
public enum RetiredHooks {
    static let flags: Set<String> = ["--permission-hook", "--session-origin-hook"]

    /// What a retired handler prints for the client waiting on it, with nothing else done; nil when `arguments` — the
    /// process's, its executable first — run no retired handler. Saying nothing to a permission request leaves the
    /// client's own prompt; a session-start or prompt hook is told to carry on.
    public static func reply(to arguments: [String]) -> String? {
        guard arguments.count == 3, flags.contains(arguments[1]) else { return nil }
        return arguments[1] == "--permission-hook" ? "" : "{}"
    }

    /// The settings files under `home` that a retired handler can be in.
    static func files(home: URL) -> [URL] {
        let files = [
            ClaudeSubscription.directory(home: home).appendingPathComponent("settings.json"),
            CodexLocator.dataDirectory(home: home).appendingPathComponent("hooks.json"),
            home.appendingPathComponent(".qoder/settings.json"),
            home.appendingPathComponent(".qoder-cn/settings.json"),
            home.appendingPathComponent(".qoderwork/settings.json"),
            CodeBuddySessions.home(home).appendingPathComponent("settings.json"),
            home.appendingPathComponent(".workbuddy/settings.json"),
            home.appendingPathComponent(".zcode/cli/config.json"),
            QwenSessions.home(home).appendingPathComponent("settings.json"),
        ]
        var seen: Set<String> = []
        return files.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Takes every retired handler that runs `executable` out of the clients' settings files under `home`, leaving
    /// everything else in them. A file that holds none is not rewritten.
    public static func remove(executable: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let prefix = HookCommand.make(executable: executable, arguments: "")
        for file in files(home: home) where FileManager.default.fileExists(atPath: file.path) {
            do {
                let object = try HookInstaller(configuration: file, arguments: "").read()
                let updated = removing(from: object, prefix: prefix)
                if updated != object { try HookSettings.write(updated, to: file) }
            } catch {
                NSLog("[AgentHUD] Could not take retired hooks out of %@: %@", file.path, error.localizedDescription)
            }
        }
    }

    /// Whether `command` runs the executable `prefix` names (`HookCommand.make` with no arguments) with the arguments of a
    /// retired handler.
    static func isRetired(_ command: String?, prefix: String) -> Bool {
        guard let command, command.hasPrefix(prefix) else { return false }
        let arguments = command.dropFirst(prefix.count).split(separator: " ")
        return arguments.count == 2 && flags.contains(String(arguments[0]))
    }

    /// `configuration` without the retired handlers that run `prefix`'s executable. Under `hooks` a handler goes, and so
    /// does whatever held only it: its matcher group, its event and, for ZCode, the event list. The `hooks` object itself
    /// stays, as it would were the hooks switched off.
    static func removing(from configuration: [String: ProviderJSON], prefix: String) -> [String: ProviderJSON] {
        var object = configuration
        if case .object(let hooks)? = object["hooks"] {
            object["hooks"] = .object(hooks.compactMapValues { prune($0, prefix: prefix) })
        }
        return object
    }

    /// What is left of `value` once the retired handlers in it are gone: nil when it was one, or when taking them out
    /// left it holding nothing but settings of its own, such as a matcher.
    private static func prune(_ value: ProviderJSON, prefix: String) -> ProviderJSON? {
        switch value {
        case .array(let items):
            let kept = items.compactMap { prune($0, prefix: prefix) }
            if kept == items { return value }
            return kept.isEmpty ? nil : .array(kept)
        case .object(let fields):
            if isRetired(fields["command"]?.stringValue, prefix: prefix) { return nil }
            let kept = fields.compactMapValues { prune($0, prefix: prefix) }
            if kept == fields { return value }
            return kept.values.contains(where: isContainer) ? .object(kept) : nil
        default:
            return value
        }
    }

    private static func isContainer(_ value: ProviderJSON) -> Bool {
        switch value {
        case .object, .array: return true
        default: return false
        }
    }
}
