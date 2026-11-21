import AgentHUDSupport
import Foundation
import XCTest
@testable import AgentHUDCore

/// The copy of the app that runs keeps Agent HUD's handlers in the clients' files pointed at itself; switching client
/// hooks off takes them all out and adds nothing back.
final class ClientHooksTests: XCTestCase, @unchecked Sendable {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func commands(_ url: URL) throws -> [String] {
        let hooks = try ProviderJSON.read(Data(contentsOf: url))["hooks"]
        return (hooks.objectValue ?? [:]).values.flatMap { $0.arrayValue ?? [] }
            .flatMap { $0["hooks"].arrayValue ?? [] }.compactMap { $0["command"].stringValue }.sorted()
    }

    func testTheSwitchIsOnUntilTurnedOff() throws {
        XCTAssertTrue(Settings().clientHooks)
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: Data(#"{"glowRange":12}"#.utf8)).clientHooks)
        let off = Settings().with { $0.clientHooks = false }
        XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(off)).clientHooks)
    }

    func testTurningHooksOffRemovesOurHandlersAndLeavesTheRest() throws {
        let home = try directory()
        for folder in [".claude/projects", ".qwen/projects", ".codex", ".copilot/session-state",
                       "Library/Application Support/Cursor/User/globalStorage"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: home.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb").path, contents: Data())
        let executable = URL(fileURLWithPath: "/Applications/Agent HUD.app/Contents/MacOS/Agent HUD")
        let running = "'\(executable.path)'", other = "'/opt/hud-bridge/bin/hud-bridge'"
        // The user's own hooks, a notification hook another build of the app added while it ran, and the approval and
        // origin handlers a fuller build installed: this copy's own, and another program's.
        let claude = home.appendingPathComponent(".claude/settings.json")
        try JSONSerialization.data(withJSONObject: ["model": "opus", "hooks": [
            "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "~/bin/lint"]]]],
            "SessionStart": [["matcher": "startup|resume", "hooks": [["type": "command", "command": "~/bin/session-log"]]],
                             ["hooks": [["type": "command", "command": "\(running) --session-origin-hook claude"]]]],
            "UserPromptSubmit": [["hooks": [["type": "command", "command": "~/bin/prompt-log"],
                                            ["type": "command", "command": "\(running) --session-origin-hook claude"]]]],
            "PermissionRequest": [["matcher": "", "hooks": [["type": "command", "command": "\(running) --permission-hook claude"]]],
                                  ["matcher": "", "hooks": [["type": "command", "command": "\(other) --permission-hook claude"]]]],
            "Notification": [["matcher": "permission_prompt", "hooks": [["type": "command",
                "command": "'/Applications/Agent HUD Open.app/Contents/MacOS/Agent HUD Open' --attention-hook claude"]]]]]]).write(to: claude)
        let codex = home.appendingPathComponent(".codex/hooks.json")
        try JSONSerialization.data(withJSONObject: ["hooks": [
            "PermissionRequest": [["matcher": "", "hooks": [["type": "command", "command": "\(running) --permission-hook codex"]]]],
            "SessionStart": [["hooks": [["type": "command", "command": "\(running) --session-origin-hook codex"]]]]]]).write(to: codex)
        // A stop hook a fuller build added for Cursor's reminders, beside the user's own.
        let cursor = home.appendingPathComponent(".cursor/hooks.json")
        try FileManager.default.createDirectory(at: cursor.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 1, "hooks": ["stop": [
            ["command": "\(running) --completion-hook cursor", "timeout": 5], ["command": "~/bin/notify"]]]]).write(to: cursor)
        func stopCommands(_ url: URL, event: String, key: String) throws -> [String] {
            try (ProviderJSON.read(Data(contentsOf: url))["hooks"][event].arrayValue ?? []).compactMap { $0[key].stringValue }
        }

        SessionObservers.configure(executable: executable, enabled: true, home: home)
        let qwen = home.appendingPathComponent(".qwen/settings.json")
        XCTAssertEqual(try commands(claude), ["\(running) --attention-hook claude", "\(other) --permission-hook claude",
                                              "~/bin/lint", "~/bin/prompt-log", "~/bin/session-log"],
                       "the notification callback beside the user's hooks, the running copy's; another program's left alone")
        let installed = try ProviderJSON.read(Data(contentsOf: claude))
        XCTAssertEqual(installed["hooks"]["SessionStart"].arrayValue?.count, 1, "a matcher group left empty goes with its handler")
        XCTAssertEqual(installed["hooks"]["UserPromptSubmit"].arrayValue?.first?["hooks"].arrayValue?.count, 1)
        XCTAssertEqual(installed["hooks"]["Notification"].arrayValue?.first?["matcher"].stringValue,
                       "permission_prompt", "the handler taken over keeps its matcher")
        XCTAssertEqual(try commands(codex), [], "Codex keeps no handler of this build")
        XCTAssertNotNil(try ProviderJSON.read(Data(contentsOf: codex))["hooks"].objectValue, "the hooks object itself stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: qwen.path), "Qwen's stop hook only fed reminders, so none is added")
        XCTAssertEqual(try stopCommands(cursor, event: "stop", key: "command"), ["~/bin/notify"],
                       "Cursor's stop hook only fed reminders, so the running copy's comes out and the user's stays")
        let copilot = home.appendingPathComponent(".copilot/hooks/agent-hud.json")
        XCTAssertEqual(try stopCommands(copilot, event: "agentStop", key: "bash"), ["\(running) --completion-hook copilot"],
                       "Copilot's stop hook ends its running turns")

        SessionObservers.configure(executable: executable, enabled: false, home: home)
        XCTAssertEqual(try commands(claude), ["\(other) --permission-hook claude", "~/bin/lint", "~/bin/prompt-log", "~/bin/session-log"])
        let removed = try ProviderJSON.read(Data(contentsOf: claude))
        XCTAssertEqual(removed["model"].stringValue, "opus")
        XCTAssertEqual(removed["hooks"]["SessionStart"].arrayValue?.first?["matcher"].stringValue, "startup|resume")
        XCTAssertFalse(FileManager.default.fileExists(atPath: qwen.path))
        XCTAssertEqual(try stopCommands(copilot, event: "agentStop", key: "bash"), [])
    }

    func testRetiredHandlersAnswerWithoutStartingTheApplication() {
        XCTAssertEqual(RetiredHooks.reply(to: ["hud", "--permission-hook", "claude"]), "",
                       "saying nothing leaves the client's own permission prompt")
        XCTAssertEqual(RetiredHooks.reply(to: ["hud", "--session-origin-hook", "codex"]), "{}")
        XCTAssertNil(RetiredHooks.reply(to: ["hud", "--attention-hook", "claude"]))
        XCTAssertNil(RetiredHooks.reply(to: ["hud", "--completion-hook", "cursor"]))
        XCTAssertNil(RetiredHooks.reply(to: ["hud", "--permission-hook"]))
        XCTAssertEqual(HookEntry.handle(arguments: ["hud", "--permission-hook", "qoder"]), 0)
        XCTAssertEqual(HookEntry.handle(arguments: ["hud", "--install-completion-hook", "cursor"]), 1,
                       "a stop hook the panel does not use is not installed")
        XCTAssertEqual(CompletionHooks.Source.allCases.filter(\.endsRunningTurns), [.copilot])
    }

    func testASettingsFileKeptAsALinkIsWrittenWhereItLeadsAndKeepsItsPermissions() throws {
        let home = try directory(), dotfiles = try directory()
        let executable = URL(fileURLWithPath: "/Applications/Agent HUD.app/Contents/MacOS/Agent HUD")
        let claude = dotfiles.appendingPathComponent("claude.json"), cursor = dotfiles.appendingPathComponent("cursor/hooks.json")
        try FileManager.default.createDirectory(at: cursor.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"model":"opus"}"#.utf8).write(to: claude)
        try Data(#"{"version":1}"#.utf8).write(to: cursor)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: claude.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: cursor.path)
        // One link names its file from the directory it sits in, the other by its whole path.
        let claudeLink = home.appendingPathComponent(".claude/settings.json"), cursorLink = home.appendingPathComponent(".cursor/hooks.json")
        for link in [claudeLink, cursorLink] {
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(atPath: claudeLink.path, withDestinationPath: "../../\(dotfiles.lastPathComponent)/claude.json")
        try FileManager.default.createSymbolicLink(atPath: cursorLink.path, withDestinationPath: cursor.path)

        try AttentionHooks.configure(.claude, enabled: true, executable: executable, home: home)
        try CompletionHooks.configure(.cursor, enabled: true, executable: executable, home: home)
        for (link, file, permissions) in [(claudeLink, claude, 0o600), (cursorLink, cursor, 0o640)] {
            XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "\(link.lastPathComponent) stays a link")
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, permissions)
        }
        XCTAssertEqual(try commands(claude).count, 1)
        XCTAssertEqual(try ProviderJSON.read(Data(contentsOf: claude))["model"].stringValue, "opus")
        XCTAssertTrue(CompletionHooks.isInstalled(.cursor, home: home))
    }

    func testRemovingNeverCreatesAFileTheClientDidNotHave() throws {
        let home = try directory(), executable = URL(fileURLWithPath: "/tmp/hud")
        for source in CompletionHooks.Source.allCases {
            try CompletionHooks.configure(source, enabled: false, executable: executable, home: home)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.configuration(home: home).path), source.rawValue)
        }
        RetiredHooks.remove(executable: executable, home: home)
        for file in RetiredHooks.files(home: home) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), file.path)
        }
    }
}
