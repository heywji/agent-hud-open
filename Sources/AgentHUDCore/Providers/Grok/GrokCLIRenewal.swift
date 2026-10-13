import Foundation
import os

/// The CLI's access token lasts six hours and only the CLI renews it, when it runs, so on a Mac where Grok has not run
/// since, the billing service rejects the stored token and no quota can be read. Running `grok models` lets the CLI
/// renew the token under its own lock and write it back. The refresh token is never used here: a rotated one the CLI
/// did not store would sign it out.
enum GrokCLIRenewal {
    /// Between attempts, so a signed-out CLI is not started on every account refresh.
    static let retryInterval: TimeInterval = 900
    static let timeout: TimeInterval = 30
    private static let lastAttempt = OSAllocatedUnfairLock<Date?>(initialState: nil)

    static func candidates(home: URL, grokHome: URL, path: String) -> [URL] {
        [grokHome.appendingPathComponent("bin/grok"), home.appendingPathComponent(".local/bin/grok"),
         URL(fileURLWithPath: "/opt/homebrew/bin/grok"), URL(fileURLWithPath: "/usr/local/bin/grok")]
            + Executables.onPath("grok", path: path)
    }

    /// Every stored login has expired, and one can still be renewed by the CLI.
    static func isRenewable(_ logins: [ProviderJSON], now: Date) -> Bool {
        !logins.isEmpty
            && logins.contains { $0["refresh_token"].stringValue?.isEmpty == false }
            && logins.allSatisfy { DateParsing.internet($0["expires_at"].stringValue).map { $0 <= now } ?? true }
    }

    /// Whether the CLI ran and exited cleanly; false without running it inside `retryInterval` of the last attempt.
    static func renew(grokHome: URL, now: Date) async -> Bool {
        let due = lastAttempt.withLock { last in
            if let last, now.timeIntervalSince(last) < retryInterval { return false }
            last = now
            return true
        }
        let environment = ProcessInfo.processInfo.environment
        guard due, let executable = Executables.first(candidates(home: FileManager.default.homeDirectoryForCurrentUser,
                                                                   grokHome: grokHome, path: environment["PATH"] ?? "")),
              let output = try? await ChildProcess.run(executable, ["models"], environment: environment,
                                                       timeout: timeout, stdoutLimit: 256 * 1024) else { return false }
        return output.status == 0
    }
}
