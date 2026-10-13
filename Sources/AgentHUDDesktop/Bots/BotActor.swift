import AppKit
import QuartzCore
import SwiftUI

extension EnvironmentValues {
    /// Whether marks show bots while working and occasionally while idle. Off, every mark stays a logo.
    @Entry var botLogos: Bool = true
}

/// One bot on screen: a layer whose picture follows the bot's look and whose transform follows how it sits.
///
/// The two are kept apart on purpose. A breathing body changes its pose every frame and its picture almost
/// never, so the picture is only drawn again when the eyes or the outline have visibly moved.
@MainActor
final class BotActor {
    let layer = CALayer()
    let form: BotForm
    private var motion: BotMotion
    private var shown: BotRenderer.Look?
    private var placed: CGAffineTransform?
    /// When the bot next needs a frame, on the clock it is stepped with; nil once it rests as its logo.
    private var due: TimeInterval? = 0
    /// A timer rarely fires on the dot: a step this close to its time is on time.
    private static let slack: TimeInterval = 0.004
    /// Side of the mark in points, the display's pixel scale, and the hairline outline in pixels.
    private var side: CGFloat = 0
    private var scale: CGFloat = 2
    private var outline = 0
    /// The colours of the display the bot is on, once its view is in a window.
    private var space: CGColorSpace?
    /// A queue's bot hides while its mark rests as the logo, because the queue draws that logo itself. A bot
    /// with nothing under it keeps its layer and draws the logo there.
    var restsHidden = true

    /// - arrivesAfter: seconds a staying bot keeps its logo before it turns into the bot.
    init(form: BotForm, staysBot: Bool, period: TimeInterval, arrivesAfter: TimeInterval = 0) {
        self.form = form
        motion = BotMotion()
        motion.staysBot = staysBot
        motion.arrivesAfter = arrivesAfter
        motion.period = max(0.5, period)
        motion.spin = form.spec.spin
        layer.contentsGravity = .resize
        layer.isHidden = true
        // Every change here is already one frame of an animation; an implicit one on top would smear it.
        layer.actions = ["contents": NSNull(), "transform": NSNull(), "hidden": NSNull(), "bounds": NSNull(),
                         "position": NSNull()]
    }

    var phase: BotPhase { motion.phase }

    /// How big the layer has to be to hold a mark `side` points wide, with its room for overflow and outline.
    static func extent(side: CGFloat, scale: CGFloat, outline: Int) -> CGFloat {
        ((side * scale * (1 + 2 * BotRenderer.margin)).rounded(.up) + CGFloat(outline) * 2) / max(1, scale)
    }

    func resize(side: CGFloat, scale: CGFloat, outline: Int) {
        guard side != self.side || scale != self.scale || outline != self.outline else { return }
        self.side = side
        self.scale = scale
        self.outline = outline
        let extent = Self.extent(side: side, scale: scale, outline: outline)
        layer.bounds = CGRect(x: 0, y: 0, width: extent, height: extent)
        layer.contentsScale = scale
        shown = nil
        due = 0
    }

    /// Frames are drawn in the colours of the display they are shown on, which a layer shows as they are. Until a
    /// display is known they are sRGB, and the layer converts each one.
    func show(in space: CGColorSpace?) {
        if let space, let current = self.space, CFEqual(space, current) { return }
        if space == nil, self.space == nil { return }
        self.space = space
        shown = nil
        due = 0
    }

    /// A phase is acted out from the next frame, however long the bot meant to wait.
    func set(_ phase: BotPhase, at now: TimeInterval) {
        motion.set(phase, at: now)
        due = 0
    }

    /// Advances to `now` once the bot is due a frame, and redraws if it looks different. Returns the seconds
    /// until it next needs one: a frame's length while it moves, the time to its next visit while an idle mark
    /// waits as its logo with the layer hidden, and nil once it rests as the logo for good.
    ///
    /// - yRunsDown: whether y grows downwards in the space this layer is laid out in.
    /// - aim: where to look, from `BotMotion.aim(from:to:)`. It is asked only while there are eyes to turn.
    func step(to now: TimeInterval, yRunsDown: Bool, aim: () -> CGPoint) -> TimeInterval? {
        guard let due else { return nil }
        if now < due - Self.slack { return due - now }
        motion.step(to: now, aim: motion.morph > 0 || motion.staysBot ? aim() : .zero)
        let wait = motion.wait
        self.due = wait.map { now + $0 }
        // Setting a layer's property, even to what it already is, makes the frame's commit carry the layer.
        if restsHidden, wait == nil || (motion.phase == .idle && !motion.staysBot && motion.morph == 0) {
            if !layer.isHidden { layer.isHidden = true }
            return wait
        }
        if layer.isHidden { layer.isHidden = false }
        let look = BotRenderer.look(of: motion)
        if look != shown, side > 0 {
            shown = look
            layer.contents = BotRenderer.image(form, motion: motion, side: side * scale, outline: outline, space: space)
        }
        let transform = Self.transform(motion.pose, side: side, yRunsDown: yRunsDown)
        if transform != placed {
            placed = transform
            layer.setAffineTransform(transform)
        }
        return wait
    }

    /// A pose is written with y running down and turns clockwise; the layer may be laid out either way up.
    nonisolated static func transform(_ pose: BotPose, side: CGFloat, yRunsDown: Bool) -> CGAffineTransform {
        let up: CGFloat = yRunsDown ? 1 : -1
        let foot = CGPoint(x: 0, y: pose.footing * side * up)
        return CGAffineTransform(translationX: pose.x * side + foot.x, y: pose.y * side * up + foot.y)
            .rotated(by: pose.rotation * .pi / 180 * up)
            .scaledBy(x: pose.scaleX, y: pose.scaleY)
            .translatedBy(x: -foot.x, y: -foot.y)
    }
}

/// One timer for every bot on screen. Each follower says how long its bots can go without a frame and the
/// timer fires at the soonest of those: every frame while something moves, a few times a second while bots only
/// breathe, and not until the next visit while every mark rests as its logo.
@MainActor
final class BotClock {
    static let shared = BotClock()
    static let frame: TimeInterval = BotPace.lively

    private var timer: Timer?
    private var followers: [ObjectIdentifier: (TimeInterval) -> TimeInterval?] = [:]

    /// Calls `step` within a frame and then again after each wait it returns, until it returns nil or `owner` is
    /// dropped. Following again brings the next call forward to now.
    func follow(_ owner: AnyObject, _ step: @escaping (TimeInterval) -> TimeInterval?) {
        followers[ObjectIdentifier(owner)] = step
        if let timer {
            let now = Date()
            if timer.fireDate > now { timer.fireDate = now }
            return
        }
        let timer = Timer(timeInterval: Self.frame, repeats: true) { _ in
            MainActor.assumeIsolated { BotClock.shared.tick() }
        }
        timer.tolerance = 0.004
        // Common modes, so bots keep moving while a menu is open or a window is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func drop(_ owner: AnyObject) {
        followers[ObjectIdentifier(owner)] = nil
        stopIfIdle()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        var soonest: TimeInterval?
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (owner, step) in followers {
            if let wait = step(now) { soonest = min(soonest ?? wait, wait) } else { followers[owner] = nil }
        }
        CATransaction.commit()
        stopIfIdle()
        // The timer repeats a frame apart by itself; a longer wait moves its next firing.
        if let soonest, soonest > Self.frame * 1.5 { timer?.fireDate = Date(timeIntervalSinceNow: soonest) }
    }

    private func stopIfIdle() {
        guard followers.isEmpty else { return }
        timer?.invalidate()
        timer = nil
    }
}

/// An agent's mark that turns into its bot. On a reminder it opens as the logo, becomes the bot once the card
/// has opened and stays it for as long as it is shown: asking on a request, smiling on a reply. A mark that
/// follows its agent instead is the bot while the agent works and the logo while it rests, as in a logo queue.
///
/// With bots switched off, or motion reduced, it is the plain logo.
struct BotMark: View {
    /// How long a reminder's mark stays the logo: the card's own opening, and a moment to read the logo in.
    static let arrival: TimeInterval = IslandAnimation.duration + 0.3

    let vendor: String
    var size: CGFloat = 17
    let phase: BotPhase
    var staysBot = true
    @Environment(\.botLogos) private var botLogos
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if botLogos, !reduceMotion, BotForm.form(for: vendor) != nil {
            BotStage(vendor: vendor, size: size, phase: phase, staysBot: staysBot)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            AgentLogo(vendor: vendor, size: size)
        }
    }
}

private struct BotStage: NSViewRepresentable {
    let vendor: String
    let size: CGFloat
    let phase: BotPhase
    let staysBot: Bool
    @Environment(\.displayScale) private var displayScale

    func makeNSView(context: Context) -> BotStageView { BotStageView() }

    func updateNSView(_ view: BotStageView, context: Context) {
        view.show(vendor: vendor, size: size, scale: displayScale, phase: phase, staysBot: staysBot)
    }

    static func dismantleNSView(_ view: BotStageView, coordinator: ()) { BotClock.shared.drop(view) }
}

/// Hosts one bot's layer, centred, with room round it for a hop.
final class BotStageView: NSView {
    private var actor: BotActor?
    private var vendor = ""
    private var staysBot = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(vendor: String, size: CGFloat, scale: CGFloat, phase: BotPhase, staysBot: Bool = true) {
        if vendor != self.vendor || staysBot != self.staysBot || actor == nil {
            self.vendor = vendor
            self.staysBot = staysBot
            actor?.layer.removeFromSuperlayer()
            actor = BotForm.form(for: vendor).map {
                let actor = BotActor(form: $0, staysBot: staysBot, period: 3, arrivesAfter: staysBot ? BotMark.arrival : 0)
                // Nothing else draws this mark, so the actor draws its logo too.
                actor.restsHidden = false
                return actor
            }
            if let actor { layer?.addSublayer(actor.layer) }
        }
        guard let actor else { return }
        actor.resize(side: size, scale: scale, outline: 0)
        actor.show(in: window?.colorSpace?.cgColorSpace)
        actor.set(phase, at: CACurrentMediaTime())
        needsLayout = true
        follow()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        actor?.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            actor?.show(in: window.colorSpace?.cgColorSpace)
            follow()
        } else {
            BotClock.shared.drop(self)
        }
    }

    private func follow() {
        guard window != nil, actor != nil else { return }
        BotClock.shared.follow(self) { [weak self] now in self?.step(to: now) }
    }

    private func step(to now: TimeInterval) -> TimeInterval? {
        guard let actor, let window else { return nil }
        return actor.step(to: now, yRunsDown: layer?.isGeometryFlipped ?? false) {
            let center = window.convertPoint(toScreen: convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil))
            let pointer = NSEvent.mouseLocation
            // Screen coordinates run up; a bot's gaze is measured with y running down.
            return BotMotion.aim(from: CGPoint(x: center.x, y: -center.y), to: CGPoint(x: pointer.x, y: -pointer.y))
        }
    }
}
