import CoreGraphics
import Foundation

/// What the agent behind a mark is doing, as far as its bot acts it out.
enum BotPhase: Sendable, Equatable {
    /// Nothing in flight: the mark rests as its logo, with a brief bot visit now and then.
    case idle
    /// A turn is running: the bot stays awake and acts in place.
    case working
    /// A turn is blocked on the user: the bot hops, stays raised and turns to face them.
    case asking
    /// A turn just ended: the bot smiles.
    case done
    /// The agent's card is being glanced at: the mark holds still as its logo, whatever its agent is doing.
    case glanced
    /// The agent's whole panel is open: the bot is up and watches the pointer for as long as it stays open.
    case opened

    /// The mark stays where its logo is, with no hop and nothing raised.
    var staysInPlace: Bool { self == .working || self == .idle || self == .glanced || self == .opened }
}

/// The bot's eyes. `look` and `lookY` are shares of a full turn of the head, right and down positive.
struct BotFace: Equatable, Sendable {
    var open: CGFloat = 1
    var look: CGFloat = 0
    var lookY: CGFloat = 0
    var wide: CGFloat = 1
    var happy: CGFloat = 0
    /// Positive grows the right eye and narrows the left, as when peering at something.
    var lean: CGFloat = 0
}

/// How the whole bot sits: offsets are shares of the mark's side, rotation is in degrees.
struct BotPose: Equatable, Sendable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rotation: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    /// Where it squashes from: 0 is the centre, 0.5 the bottom edge.
    var footing: CGFloat = 0

    func mixed(with other: BotPose, _ share: CGFloat) -> BotPose {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * share }
        return BotPose(x: mix(x, other.x), y: mix(y, other.y), rotation: mix(rotation, other.rotation),
                       scaleX: mix(scaleX, other.scaleX), scaleY: mix(scaleY, other.scaleY),
                       footing: mix(footing, other.footing))
    }
}

/// How long a bot can go without a frame. Every frame it is drawn costs a picture or at least a move of its
/// layer, so it asks for no more of them than its motion can show.
enum BotPace {
    /// A morph, an act, a blink or a hop.
    static let lively: TimeInterval = 1.0 / 30
    /// Eyes following the pointer.
    static let following: TimeInterval = 1.0 / 15
    /// Nothing but a breath and a slow turn, which move a fraction of a pixel in this long.
    static let calm: TimeInterval = 1.0 / 10
}

/// One bot's state over time: how far the logo has turned into the bot, what its eyes are doing and how it
/// sits. It is stepped with a clock and nothing else, so the same seed and the same times give the same bot.
struct BotMotion: Sendable {
    private static let morphSeconds: TimeInterval = 0.5
    /// The most time one step moves the bot by.
    private static let longestStep: TimeInterval = 0.1
    /// How long after a turn ended its mark rests as the logo again.
    private static let doneSeconds: TimeInterval = 2.4
    /// An alert shows its bot for as long as the alert is up; a logo queue lets it settle back into the logo.
    var staysBot = false
    /// Seconds a staying bot keeps its logo after it is first given a phase. A reminder's card is still opening
    /// then, so the mark is read as the agent's logo before it turns into the bot. The phase begins on arrival.
    var arrivesAfter: TimeInterval = 0
    /// Seconds for one breath of the body.
    var period: TimeInterval = 3
    /// Degrees per second the body turns under the face while awake.
    var spin: CGFloat = 0

    private(set) var phase: BotPhase = .idle
    private(set) var since: TimeInterval = -10
    /// 0 is the logo, 1 the bot.
    private(set) var morph: CGFloat = 0
    private(set) var face = BotFace()
    private(set) var pose = BotPose()
    /// Degrees the body has turned.
    private(set) var turn: CGFloat = 0
    /// The piece a mark keeps above its body: how far it has hopped, and how big it is.
    private(set) var kept = (lift: CGFloat(0), scale: CGFloat(1))
    /// Seconds from the last step until the bot next needs a frame: a frame's length while it moves, the time to
    /// its next visit while it waits as its logo, and nothing once it rests as the logo for good.
    private(set) var wait: TimeInterval? = BotPace.lively

    private var last: TimeInterval?
    private var leaving: BotPose?
    private var act: Act?
    private var nextAct: TimeInterval = 0
    private var blinks: [TimeInterval] = [-1, -1]
    private var nextBlink: TimeInterval = 2
    /// The eyes are still on their way to where they should look, or a lid is still moving.
    private var following = false, blinking = false
    /// The next brief bot visit while idle, between longer stretches as the original logo.
    private var botInterval: Range<TimeInterval>?
    private var random: SplitMix

    private struct Act {
        enum Kind: CaseIterable { case glance, blinkTwice, squint, widen, smile, inspect, tilt, stretch, wiggle, turn }
        var kind: Kind
        var start: TimeInterval
        var length: TimeInterval
        var side: CGFloat
        var gaze: CGPoint
        var from: CGFloat
    }

    init(seed: UInt64 = UInt64.random(in: 0...UInt64.max)) { random = SplitMix(state: seed) }

    /// Nothing left to draw or wait for: the logo is back and at rest.
    var isAtRest: Bool {
        guard morph == 0, !staysBot else { return false }
        switch phase {
        case .idle: return botInterval == nil && pose == BotPose()
        case .done: return (last ?? 0) - since > Self.doneSeconds
        case .glanced: return pose == BotPose()
        case .working, .asking, .opened: return false
        }
    }

    mutating func set(_ next: BotPhase, at now: TimeInterval) {
        guard next != phase else {
            if next == .idle, !staysBot, botInterval == nil { scheduleBot(after: now) }
            return
        }
        leaving = pose
        phase = next
        since = now + (staysBot && morph == 0 ? max(0, arrivesAfter) : 0)
        if next == .working {
            nextAct = now + 0.9 + random.unit() * 1.2
        } else if next == .opened {
            nextAct = now + 0.9 + random.unit() * 1.2
        }
        botInterval = nil
        if next == .idle, !staysBot { scheduleBot(after: now + Double(morph) * Self.morphSeconds) }
    }

    /// Advances to `now`. `aim` is where the bot should look, as returned by `BotMotion.aim(from:to:)`.
    mutating func step(to now: TimeInterval, aim: CGPoint = .zero, hasFace: Bool = true) {
        // Time the clock slept through moves nothing: a bot woken for its visit starts from where it stopped.
        let gap = max(0, now - (last ?? now))
        let dt = gap > 2 * Self.longestStep ? 0 : min(Self.longestStep, gap)
        last = now
        let age = now - since
        if phase == .idle, !staysBot, let interval = botInterval, now >= interval.upperBound {
            scheduleBot(after: now + Self.morphSeconds)
        }
        let idleVisit = phase == .idle && botInterval?.contains(now) == true
        // Before a staying bot arrives it is the logo at rest: no morph, no pose, no face.
        let arrived = age >= 0
        let awake = arrived && (phase == .working || idleVisit || phase == .asking || phase == .opened
                                || (phase == .done && age < 1.5))

        let wanted: CGFloat = arrived && (awake || staysBot) && hasFace ? 1 : 0
        let stride = CGFloat(dt / Self.morphSeconds)
        morph = abs(wanted - morph) <= stride ? wanted : morph + (wanted > morph ? stride : -stride)

        // Random life while awake: one small act, a pause, another.
        if let running = act, now - running.start >= running.length {
            if running.kind == .turn { turn = running.from + 60 * running.side }
            act = nil
        }
        let actsInPlace = phase.staysInPlace
        if actsInPlace {
            if awake || staysBot, morph > 0.9 || !hasFace, act == nil, now >= nextAct {
                let chosen = pick(at: now)
                act = chosen
                nextAct = now + chosen.length + 0.5 + random.unit() * 1.9
                if chosen.kind == .blinkTwice { blinks = [now, now + 0.24] }
            }
        } else {
            act = nil
        }
        let progress = act.map { CGFloat((now - $0.start) / $0.length) } ?? 0
        let swell = act == nil ? 0 : Self.easeInOut(min(1, min(progress / 0.22, (1 - progress) / 0.22)))
        if actsInPlace, morph > 0.5, spin != 0 {
            if let act, act.kind == .turn { turn = act.from + 60 * act.side * Self.easeInOut(progress) }
            else { turn += spin * CGFloat(dt) }
        }

        pose = arrived ? sitting(age: age, progress: progress, swell: swell) : BotPose()
        if let leaving, arrived, age < 0.3 { pose = leaving.mixed(with: pose, Self.easeOut(CGFloat(age / 0.3))) }
        if actsInPlace {
            // Keep the centre fixed, even when returning from an alert's raised pose. The original logo
            // is still while it is shown; breathing and turns arrive with the bot again.
            pose = BotPose().mixed(with: pose, morph)
            pose.x = 0
            pose.y = 0
            pose.footing = 0
        } else if morph > 0.5 {
            pose.x += 0.025 * face.look
        }

        if arrived, !actsInPlace || morph > 0 { look(age: age, now: now, dt: dt, aim: aim, swell: swell) }
        else { (following, blinking) = (false, false) }
        if arrived { keep(age: age, now: now, dt: dt) }
        wait = nextFrame(now: now, age: age, wanted: wanted)
    }

    private func nextFrame(now: TimeInterval, age: TimeInterval, wanted: CGFloat) -> TimeInterval? {
        if isAtRest { return nil }
        // A logo waiting to arrive shows nothing new until it does.
        if age < 0 { return max(BotPace.lively, -age) }
        if morph == 0, wanted == 0 {
            // The logo is showing: nothing moves before an idle mark's next visit, or a finished turn's rest.
            if phase == .idle, let visit = botInterval { return max(BotPace.lively, visit.lowerBound - now) }
            if phase == .done { return max(BotPace.lively, since + Self.doneSeconds - now + 0.01) }
            return BotPace.lively
        }
        if morph != wanted || act != nil || blinking || age < 0.3 { return BotPace.lively }
        switch phase {
        case .asking:
            // The hop, then a knock every few seconds; between knocks only the kept piece pulses.
            let knock = (age - 1.2).truncatingRemainder(dividingBy: 2.6)
            return age < 1.2 || knock < 0.55 ? BotPace.lively : BotPace.following
        case .done:
            if age < 1.5 { return BotPace.lively }
        case .working, .idle, .glanced, .opened:
            break
        }
        return following ? BotPace.following : BotPace.calm
    }

    /// Where a bot centred at `center` should look to face `target`, both in the same y-down coordinates.
    /// Something close by turns the head less than something far away.
    static func aim(from center: CGPoint, to target: CGPoint) -> CGPoint {
        let dx = target.x - center.x, dy = target.y - center.y, distance = hypot(dx, dy)
        guard distance >= 1 else { return .zero }
        let share = distance / (distance + 120)
        return CGPoint(x: dx / distance * share, y: dy / distance * share)
    }

    // MARK: Body

    private mutating func scheduleBot(after now: TimeInterval) {
        let start = now + 20 + random.unit() * 15
        // Fade-in is part of this interval; fade-out follows it. Together the visit lasts 3–5 seconds.
        botInterval = start..<(start + 3 + random.unit() * 2 - Self.morphSeconds)
        nextAct = start + Self.morphSeconds
    }

    private func sitting(age: TimeInterval, progress: CGFloat, swell: CGFloat) -> BotPose {
        var pose = BotPose()
        let t = CGFloat(age)
        switch phase {
        case .working, .idle, .glanced, .opened:
            // Breathing changes the body's shape around its fixed centre.
            let breath = 2 * CGFloat.pi * CGFloat(age / period)
            pose.scaleX = 1 + 0.03 * sin(2 * breath)
            pose.scaleY = 1 - 0.03 * sin(2 * breath)
        case .asking:
            if t < 0.45 {
                let x = t / 0.45, arc = sin(.pi * x)
                pose.y = -0.26 * 4 * x * (1 - x)
                pose.scaleY = 1 + 0.08 * arc
                pose.scaleX = 1 - 0.05 * arc
            }
            let raised = 1 + 0.12 * Self.easeOutBack(min(1, t / 0.35))
            pose.scaleX *= raised
            pose.scaleY *= raised
            // A knock every few seconds, until it is answered.
            let cycle = (t - 1.2).truncatingRemainder(dividingBy: 2.6)
            if t > 1.2, cycle < 0.55 {
                let x = cycle / 0.55
                pose.rotation = 8 * sin(2 * .pi * 2.5 * x) * (1 - x)
            }
        case .done:
            if t < 0.6 {
                let pop = sin(.pi * t / 0.6)
                pose.scaleX = 1 + 0.2 * pop
                pose.scaleY = 1 + 0.2 * pop
                pose.y = -0.1 * pop
            }
        }
        guard let act else { return pose }
        switch act.kind {
        case .tilt: pose.rotation += act.side * 9 * swell
        case .stretch:
            let arc = sin(.pi * progress)
            pose.scaleY *= 1 + 0.06 * arc
            pose.scaleX *= 1 - 0.04 * arc
        case .wiggle: pose.rotation += 8 * sin(2 * .pi * 3 * progress) * (1 - progress)
        default: break
        }
        return pose
    }

    // MARK: Face

    private mutating func look(age: TimeInterval, now: TimeInterval, dt: TimeInterval, aim: CGPoint, swell: CGFloat) {
        var target = BotFace()
        var every: ClosedRange<TimeInterval>? = 3.2...6.5
        switch phase {
        case .working, .idle, .glanced, .opened:
            target.look = aim.x
            target.lookY = aim.y
            every = 2.2...4.5
            if let act {
                switch act.kind {
                case .glance:
                    // A glance looks away and comes back.
                    target.look += (act.gaze.x * 0.8 - target.look) * swell
                    target.lookY += (act.gaze.y - target.lookY) * swell
                case .squint: target.open = 1 - 0.55 * swell
                case .widen: target.wide = 1 + 0.2 * swell
                case .smile: target.happy = swell > 0.4 ? 1 : 0
                case .inspect:
                    target.lean = act.side * swell
                    target.look += (act.side * 0.6 - target.look) * swell
                    target.lookY -= target.lookY * swell
                default: break
                }
            }
        case .asking:
            // Straight at the user, wide open, and no blinking until the stare has landed.
            target.wide = 1.22
            every = age < 1.5 ? nil : 4...7
        case .done:
            if age < 1.25 {
                target.happy = 1
                every = nil
            } else {
                target.look = aim.x
                target.lookY = aim.y
            }
        }

        let eyes = CGFloat(1 - exp(-dt * 18)), head = CGFloat(1 - exp(-dt * 9))
        face.look += (target.look - face.look) * head
        face.lookY += (target.lookY - face.lookY) * head
        face.wide += (target.wide - face.wide) * eyes
        face.happy += (target.happy - face.happy) * eyes
        face.lean += (target.lean - face.lean) * eyes

        var lid = target.open
        if let every {
            if now >= nextBlink {
                blinks = [now, -1]
                nextBlink = now + every.lowerBound + random.unit() * (every.upperBound - every.lowerBound)
            }
        } else if nextBlink < now {
            nextBlink = now + 1.2
        }
        for start in blinks {
            let blink = (now - start) / 0.17
            if blink >= 0, blink < 1 { lid *= 1 - CGFloat(sin(.pi * blink)) }
        }
        face.open += (lid - face.open) * CGFloat(1 - exp(-dt * 60))
        // Finer than the steps a picture is drawn in, so the last frame of a move is the settled one.
        blinking = abs(lid - face.open) > 0.01 || blinks.contains { now >= $0 && now - $0 < 0.17 }
        following = abs(target.look - face.look) > 0.004 || abs(target.lookY - face.lookY) > 0.004
            || abs(target.wide - face.wide) > 0.004 || abs(target.happy - face.happy) > 0.01
            || abs(target.lean - face.lean) > 0.01
    }

    private mutating func keep(age: TimeInterval, now: TimeInterval, dt: TimeInterval) {
        guard !phase.staysInPlace else {
            kept = (lift: 0, scale: 1)
            return
        }
        var lift: CGFloat = 0, scale: CGFloat = 1
        switch phase {
        case .working, .idle, .glanced, .opened:
            break
        case .asking:
            lift = 0.03
            scale = 1.22 + 0.08 * CGFloat(sin(2 * .pi * now / 0.8))
        case .done:
            if age < 0.6 { lift = 0.22 * CGFloat(sin(.pi * age / 0.6)) }
        }
        let ease = CGFloat(1 - exp(-dt * 22))
        kept.lift += (lift - kept.lift) * ease
        kept.scale += (scale - kept.scale) * ease
    }

    // MARK: Acts

    private mutating func pick(at now: TimeInterval) -> Act {
        var pool: [(Act.Kind, Double)] = [(.glance, 5), (.blinkTwice, 2), (.squint, 2), (.widen, 2), (.smile, 2),
                                          (.inspect, 2), (.tilt, 3), (.stretch, 2), (.wiggle, 2)]
        if spin != 0 { pool.append((.turn, 3)) }
        var roll = random.unit() * pool.reduce(0) { $0 + $1.1 }
        var kind = pool[0].0
        for (candidate, weight) in pool {
            roll -= weight
            if roll < 0 { kind = candidate; break }
        }
        let length: TimeInterval
        switch kind {
        case .glance: length = 1.1 + random.unit() * 0.7
        case .blinkTwice: length = 0.5
        case .squint: length = 1.2
        case .widen: length = 0.9
        case .smile: length = 1.1
        case .inspect: length = 1.5
        case .tilt: length = 1.1
        case .stretch: length = 0.55
        case .wiggle: length = 0.6
        case .turn: length = 0.7
        }
        let angle = random.unit() * 2 * .pi
        return Act(kind: kind, start: now, length: length, side: random.unit() < 0.5 ? -1 : 1,
                   gaze: CGPoint(x: cos(angle), y: sin(angle) * 0.7), from: turn)
    }

    // MARK: Curves

    static func easeInOut(_ x: CGFloat) -> CGFloat { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
    static func easeOut(_ x: CGFloat) -> CGFloat { 1 - pow(1 - x, 3) }
    static func easeOutBack(_ x: CGFloat) -> CGFloat {
        let c: CGFloat = 1.70158
        return 1 + (c + 1) * pow(x - 1, 3) + c * pow(x - 1, 2)
    }
}

/// A small seeded generator, so a bot's random acts can be replayed in a test.
struct SplitMix: Sendable {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    /// 0 up to, not including, 1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
