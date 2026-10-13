import AppKit
import AgentHUDCore

/// Plays a demo script against the running demo. Each step changes the stage the demo's provider reports from, the
/// requests waiting, or the panel, and the HUD follows as it follows real sources: nothing is drawn by the script.
@MainActor
final class DemoScriptRunner {
    /// What a step reaches into the app with.
    struct Effects {
        /// Read a report now; the stage has changed what the provider says.
        var refresh: @MainActor () -> Void
        var showRequests: @MainActor ([(id: String, at: Date)]) -> Void
        var setPanel: @MainActor (Bool) -> Void
    }

    private let script: DemoScript
    private let effects: Effects
    private var stage: DemoStage
    private var next = 0
    private var startedAt: Date
    private var timer: Timer?

    /// - now: when the script starts, on the demo's clock like every time it is given. The stage is set at once, so a
    ///   report read before `start` already follows it.
    init(script: DemoScript, effects: Effects, now: Date = DemoClock.now) {
        self.script = script
        self.effects = effects
        startedAt = now
        stage = DemoStage(script: script, now: now)
        DemoStageBox.current = stage
    }

    /// A runner for a built-in script or a JSON file, wired to the store and the island; nil, with the reason logged,
    /// when there is no such script, so the demo runs as it does without one.
    static func load(_ nameOrPath: String, store: UsageStore, island: IslandController) -> DemoScriptRunner? {
        do {
            return DemoScriptRunner(script: try DemoScript.load(nameOrPath), effects: Effects(
                refresh: { [weak store] in Task { await store?.refresh() } },
                // A request's card counts the seconds it has waited on the wall clock.
                showRequests: { PermissionRequests.shared.showDemo($0.map { ($0.id, DemoClock.wallTime(of: $0.at)) }) },
                setPanel: { [weak island] open in open ? island?.forceOpen() : island?.forceCollapse() }
            ))
        } catch {
            NSLog("[AgentHUD] The demo script %@ could not be read: %@", nameOrPath, String(describing: error))
            return nil
        }
    }

    func start(now: Date = DemoClock.now) {
        startedAt = now
        next = 0
        effects.showRequests(stage.requests)
        schedule(after: advance(to: now))
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        DemoStageBox.current = nil
    }

    /// Performs every step due by `now`, starting over when a repeating script has run out. Returns the seconds until
    /// there is more to do, or nil once a script that plays once has ended.
    @discardableResult
    func advance(to now: Date) -> TimeInterval? {
        let elapsed = now.timeIntervalSince(startedAt)
        var reported = false, queued = false
        while next < script.steps.count, script.steps[next].at <= elapsed + 0.001 {
            let action = script.steps[next].action
            next += 1
            if case .panel(let open) = action {
                effects.setPanel(open)
            } else if stage.apply(action, at: now) {
                reported = true
            } else {
                queued = true
            }
        }
        if reported || queued { publish(reported: reported) }
        if next < script.steps.count { return max(0, script.steps[next].at - elapsed) }
        guard let pause = script.repeatAfter else { return nil }
        let wait = script.length + max(1, pause) - elapsed
        guard wait <= 0.001 else { return wait }
        startedAt = now
        next = 0
        stage.restart(script: script, now: now)
        effects.setPanel(false)
        publish(reported: true)
        return advance(to: now)
    }

    private func publish(reported: Bool) {
        DemoStageBox.current = stage
        effects.showRequests(stage.requests)
        if reported { effects.refresh() }
    }

    private func schedule(after wait: TimeInterval?) {
        timer?.invalidate()
        guard let wait else { return }
        let timer = Timer(timeInterval: max(0.01, wait), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.schedule(after: self.advance(to: DemoClock.now))
            }
        }
        // Common modes, so the script keeps time while a menu is open or the HUD is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
