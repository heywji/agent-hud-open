import AppKit
import AgentHUDCore
import SwiftUI

/// One screen's HUD: its island window, the shadow under it and its own hover state machine.
///
/// Everything here belongs to a single display, because two displays can be in different modes, be hovered
/// independently and show different things. What is shared — the store, the settings, the system appearance,
/// the pointer — is handed down by `IslandController`, which owns one of these per screen.
@MainActor
final class ScreenHUD {
    /// Height of the open panel; follows the content reported by `IslandRootView`.
    private var panelHeight: CGFloat = IslandController.defaultPanelHeight

    /// The display this HUD lives on, looked up again each time: `NSScreen` instances are replaced when
    /// displays change, while the key outlives them.
    let key: String
    private let store: UsageStore
    private let settings: SettingsStore
    private let mouseLocation: @MainActor () -> CGPoint
    private let renderMaterials: @Sendable (ShadowWindowController.PreparationInputs) async -> ShadowWindowController.PreparedImages
    private(set) var geometry: NotchGeometry
    /// Set by the coordinator, which watches the system appearance once for every screen.
    var systemIsLight = SystemAppearance.isLight
    let shadow: ShadowWindowController
    let island: IslandWindowController
    private var machine = HoverMachine()
    /// One owner for the next surface's measurements and shadow bitmap, including opening and collapse.
    private var materialPreparation: MaterialPreparation? {
        didSet { oldValue?.task?.cancel() }
    }
    private var timer: Timer?
    private var targetWindowFrame: CGRect?
    /// The card whose geometry is still interpolating; canvas-only changes share its completion.
    private var geometryTransitionFrame: CGRect?
    private var pointerInside = false
    /// Whether the hover currently counts as one that opens the panel; see `reevaluateHover`.
    private var hoverOpens = false
    private var modifierWatch: Timer?
    private let dragSurface = HUDDragWindowController()
    /// A drag is previewed without writing preferences on every mouse movement; mouse-up commits once.
    private var previewPlacement: ScreenPlacement?
    /// The grip along the strip, kept when the queue turns onto another edge.
    private var dragGrabFraction: CGFloat = 0.5

    /// Inputs that can change the natural layout while a hover is waiting, including token data that
    /// need not change the coordinator's quota rows.
    private struct PanelInputs: Equatable {
        let report: UsageReport?
        let settings: AgentHUDCore.Settings
        let agents: [AgentDescriptor]
        let hookTurns: [String: SessionPhase.HookTurn]
        let now: Date
        let dataDate: Date
        let error: String?
        let loading: Bool
        let geometry: NotchGeometry
        let light: Bool
        let reduceMotion: Bool
    }

    private final class MaterialPreparation {
        let inputs: PanelInputs
        let open: Bool
        let surface: Surface
        let height: CGFloat
        let task: Task<ShadowWindowController.PreparedImages?, Never>?
        var images: ShadowWindowController.PreparedImages?

        init(inputs: PanelInputs, open: Bool, surface: Surface, height: CGFloat,
             task: Task<ShadowWindowController.PreparedImages?, Never>?) {
            self.inputs = inputs
            self.open = open
            self.surface = surface
            self.height = height
            self.task = task
        }
    }

    private var panelInputs: PanelInputs {
        PanelInputs(report: store.report, settings: settings.settings, agents: settings.agents,
                    hookTurns: store.hookTurns, now: store.now, dataDate: store.dataDate,
                    error: store.lastError, loading: store.isLoading, geometry: geometry, light: systemIsLight,
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    var onOpenSettings: (() -> Void)?

    init(key: String, screen: NSScreen?, store: UsageStore, settings: SettingsStore,
         mouseLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
         renderMaterials: @escaping @Sendable (ShadowWindowController.PreparationInputs) async -> ShadowWindowController.PreparedImages
            = { ShadowWindowController.render($0) }) {
        self.key = key
        self.store = store
        self.settings = settings
        self.mouseLocation = mouseLocation
        self.renderMaterials = renderMaterials
        // The stored placement decides notch or queue before the first frame, so the HUD never flashes
        // the wrong shape on launch.
        let placement = screen.map { ScreenIdentity.placement(for: $0, in: settings.settings) }
            ?? .default(hasNotch: false)
        let geometry = NotchGeometry.detect(screen: screen, placement: placement)
        self.geometry = geometry
        shadow = ShadowWindowController(geometry: geometry)
        island = IslandWindowController(frame: geometry.islandFrame, rootView: IslandRootView.placeholder)
        island.onPointerChange = { [weak self] _ in self?.samplePointer() }
        dragSurface.onPress = { [weak self] in self?.grabHUD() }
        dragSurface.onRelease = { [weak self] in self?.releaseHUD() }
        dragSurface.onBegin = { [weak self] point in self?.beginMoving(at: point) }
        dragSurface.onDrag = { [weak self] point in self?.move(to: point) }
        dragSurface.onEnd = { [weak self] in self?.finishMoving() }

        apply(animated: false)
        island.show()
    }

    // MARK: Hover

    func pointer(inside: Bool) {
        guard previewPlacement == nil else { return }
        if pointerInside != inside {
            pointerInside = inside
            // Whether Option is down can change without the pointer moving, so while it is over the HUD the
            // modifier is watched. A global keyboard monitor would ask for accessibility; this does not.
            modifierWatch?.invalidate()
            modifierWatch = nil
            if inside, settings.settings.requiresOptionToOpen {
                modifierWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.reevaluateHover() }
                }
            }
        }
        // Moving within the HUD can reach the top while an ordinary hover is still waiting to open.
        reevaluateHover()
    }

    /// The bare island canvas passes clicks through. A visible strip has its own small grab surface.
    /// Hover is followed by the coordinator, while an open island takes events for its controls.
    private func updateClickThrough(_ passes: Bool) {
        guard island.panel.ignoresMouseEvents != passes else { return }
        island.panel.ignoresMouseEvents = passes
    }

    /// The region that counts as hovering: the marks while collapsed, the panel once it is open. The target frame
    /// rather than the window's, which is briefly grown into a canvas for the opening animation.
    func samplePointer() {
        pointer(inside: Self.containsPointer(mouseLocation(), in: hoverRegion))
    }

    /// CGRect.contains excludes its top and right edges. A pointer pinned to a display edge is still
    /// over the HUD, including at the physical notch, so hover includes the target's boundary.
    static func containsPointer(_ point: CGPoint, in region: CGRect) -> Bool {
        !region.isEmpty && point.x >= region.minX && point.x <= region.maxX
            && point.y >= region.minY && point.y <= region.maxY
    }

    /// AppKit's pointer may stop one point short of maxY at a physical display boundary.
    /// Only the HUD's own top edge qualifies; side and bottom queues keep their ordinary hover delay.
    static func pointerTouchesTop(_ point: CGPoint, geometry: NotchGeometry) -> Bool {
        geometry.edge == .top && point.y >= geometry.screenFrame.maxY - 1
            && point.y <= geometry.screenFrame.maxY && containsPointer(point, in: geometry.rect)
    }

    private var hoverRegion: CGRect {
        ScreenHUD.hoverRegion(open: machine.isOpen, panel: targetWindowFrame ?? island.panel.frame, marks: geometry.rect)
    }

    /// Which shape the pointer has to be inside to count as hovering this HUD.
    static func hoverRegion(open: Bool, panel: CGRect, marks: CGRect) -> CGRect {
        open ? panel : marks
    }

    /// Hovering opens the panel, unless the user asked for Option as well.
    private func reevaluateHover() {
        guard !dragSurface.isPressed, previewPlacement == nil else { return }
        let opens = ScreenHUD.opensOnHover(counted: hoverOpens, open: machine.isOpen, pointerInside: pointerInside,
                                           requiresOption: settings.settings.requiresOptionToOpen,
                                           optionDown: NSEvent.modifierFlags.contains(.option))
        let canFinishOpening = switch machine.state {
        case .opening: true
        // A handoff to Settings deliberately stays collapsed until the pointer leaves.
        case .collapsed: !hoverOpens
        default: false
        }
        if opens, canFinishOpening, settings.settings.openImmediatelyAtTop,
           Self.pointerTouchesTop(mouseLocation(), geometry: geometry) {
            hoverOpens = true
            transition(machine.reduce(.forceOpen, config: config))
            return
        }
        guard opens != hoverOpens else { return }
        hoverOpens = opens
        let now = Date()
        transition(machine.reduce(opens ? .pointerEntered(at: now) : .pointerExited(at: now), config: config))
    }

    /// Whether the hover counts as one that opens the panel; `counted` is whether it already does. Option is asked for
    /// only to start it: a tap is enough, and from then on the hover counts until the pointer leaves. An open panel
    /// needs no Option either — it is being read and pointed at, including by a pointer that slipped off the edge and
    /// came back before it closed.
    static func opensOnHover(counted: Bool, open: Bool, pointerInside: Bool, requiresOption: Bool, optionDown: Bool) -> Bool {
        pointerInside && (counted || open || !requiresOption || optionDown)
    }

    func forceOpen() {
        transition(machine.reduce(.forceOpen, config: config))
    }

    func forceCollapse() {
        transition(machine.reduce(.forceCollapse, config: config))
    }

    /// A click that opens another window takes the HUD down first: the panel floats above every window and stays open
    /// while the pointer rests on it, so the window it opened would appear underneath it. The pointer has to leave and
    /// come back to open it again.
    private func handOff(_ open: () -> Void) {
        forceCollapse()
        open()
    }

    private var config: HoverMachine.Config {
        HoverMachine.Config(hoverDelay: settings.settings.hoverDelay, collapseDelay: settings.settings.collapseDelay)
    }

    private func transition(_ transition: HoverMachine.Transition) {
        let wasOpen = machine.isOpen
        machine = transition.machine
        timer?.invalidate()
        timer = nil
        if let deadline = transition.deadline {
            let interval = max(0.001, deadline.timeIntervalSinceNow)
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.timerFired() }
            }
        }
        if case .opening = machine.state {
            prepareOpening()
        } else if !machine.isOpen {
            materialPreparation = nil
        }
        if wasOpen != machine.isOpen {
            // The panel opening is someone looking at the numbers, which is reason enough to read the accounts again.
            if machine.isOpen { Task { await store.refreshAccounts() } }
            apply(animated: true)
        }
    }

    private func timerFired() {
        if case .opening(let deadline) = machine.state {
            // Validate even when a report changed without a coordinator apply. The worker, rather than a
            // synchronous raster fallback, finishes an opening whose delay expired before its bitmap was ready.
            prepareOpening()
            if Date() >= deadline, materialPreparation?.images == nil {
                timer?.invalidate()
                timer = nil
                return
            }
        }
        transition(machine.reduce(.timerFired(at: Date()), config: config))
    }

    // MARK: Layout

    private var maximumContentHeight: CGFloat {
        geometry.screenFrame.height - 80
    }

    /// Resizes the open panel to its content (rows come and go as windows are discovered).
    private func updatePanelHeight(_ height: CGFloat) {
        let clamped = max(80, min(height.rounded(), maximumContentHeight))
        guard clamped > 0, abs(clamped - panelHeight) >= 1 else { return }
        panelHeight = clamped
        if machine.isOpen { apply(animated: true) }
    }

    /// This HUD's own display, or nothing once it has been unplugged.
    var screen: NSScreen? {
        NSScreen.screens.first { ScreenIdentity.key(for: $0) == key }
    }

    private var placement: ScreenPlacement {
        previewPlacement ?? screen.map { ScreenIdentity.placement(for: $0, in: settings.settings) } ?? .default(hasNotch: false)
    }

    // MARK: Repositioning

    private func updateDragSurface() {
        let visibleHUD = geometry.mode == .notch || logoQueue != nil
        guard visibleHUD || previewPlacement != nil || dragSurface.isPressed else {
            dragSurface.hide()
            return
        }
        dragSurface.show(frame: Self.dragSurfaceFrame(for: geometry),
                         outlined: previewPlacement != nil || dragSurface.isArmed)
    }

    /// The dashed bounds leave room at both ends of the queue without moving its marks.
    static func dragSurfaceFrame(for geometry: NotchGeometry) -> CGRect {
        var frame = geometry.rect.insetBy(dx: geometry.edge.isHorizontal ? -8 : 0,
                                         dy: geometry.edge.isHorizontal ? 0 : -8)
        // The physical notch cannot be clicked. A little space beneath it makes its move surface reachable.
        if geometry.mode == .notch { frame.origin.y -= 14; frame.size.height += 14 }
        return frame.intersection(geometry.screenFrame)
    }

    private func grabHUD() {
        materialPreparation = nil
        timer?.invalidate()
        timer = nil
        if !machine.isOpen { machine = HoverMachine(); hoverOpens = false }
        updateDragSurface()
    }

    private func releaseHUD() {
        updateDragSurface()
        if previewPlacement == nil { samplePointer() }
    }

    func beginMoving(at point: CGPoint? = nil) {
        materialPreparation = nil
        if let point {
            let run = geometry.edge.isHorizontal ? geometry.rect.width : geometry.rect.height
            let grip = geometry.edge.isHorizontal ? point.x - geometry.rect.minX : geometry.rect.maxY - point.y
            dragGrabFraction = min(1, max(0, grip / run))
        } else {
            dragGrabFraction = 0.5
        }
        previewPlacement = placement
        if previewPlacement?.mode == .notch { previewPlacement?.mode = .logos }
        timer?.invalidate()
        timer = nil
        targetWindowFrame = nil
        geometryTransitionFrame = nil
        machine = HoverMachine()
        hoverOpens = false
        apply(animated: false)
    }

    func move(to point: CGPoint) {
        guard let current = previewPlacement else { return }
        previewPlacement = NotchGeometry.dragPlacement(at: point, screenFrame: geometry.screenFrame,
                                                       queue: queueSize(for: current), placement: current,
                                                       grabFraction: dragGrabFraction)
        apply(animated: false)
    }

    func finishMoving() {
        guard let next = previewPlacement else { return }
        settings.update { $0.screens[key] = next }
        previewPlacement = nil
        // Dropping the HUD is an explicit repositioning, not a request to open its panel under the pointer.
        hoverOpens = true
        apply(animated: false)
        pointerInside = Self.containsPointer(mouseLocation(), in: hoverRegion)
    }

    private func queueSize(_ config: LogoQueueConfig) -> CGSize {
        guard config.items.isEmpty else { return config.size }
        let run = max(32, config.logo)
        return config.edge.isHorizontal ? CGSize(width: run, height: config.stripThickness) : CGSize(width: config.stripThickness, height: run)
    }

    /// What a logo queue takes along its edge: the watched agents and anything else run in the last day.
    private func queueSize(for placement: ScreenPlacement) -> CGSize {
        queueSize(LogoQueueConfig(items: queueItems, placement: placement))
    }

    /// The marks this screen shows: the watched agents and anything else run in the last day.
    private var queueItems: [LogoQueueItem] {
        LogoQueueItem.queue(rows: store.queueVendors)
    }

    /// A docked mode sizes its strip from what it has to hold.
    private func resolveGeometry() -> NotchGeometry {
        let screen = screen
        let placement = placement
        guard placement.mode.isDocked else { return NotchGeometry.detect(screen: screen, placement: placement) }
        return NotchGeometry.detect(screen: screen, placement: placement, queue: queueSize(for: placement))
    }

    private var logoQueue: LogoQueueConfig? {
        // The geometry still measures the queue when the marks are hidden, so the strip keeps the place and
        // the width it had; only the drawing stops.
        guard geometry.mode == .logos, placement.showsLogos else { return nil }
        let config = LogoQueueConfig(items: queueItems, placement: placement)
        return config.items.isEmpty ? nil : config
    }

    /// Takes this HUD's windows off screen; the display it belonged to is gone.
    func close() {
        materialPreparation = nil
        modifierWatch?.invalidate()
        timer?.invalidate()
        targetWindowFrame = nil
        geometryTransitionFrame = nil
        island.panel.orderOut(nil)
        shadow.close()
        dragSurface.hide()
    }

    private func makeRoot(open: Bool, animated: Bool) -> IslandRootView {
        var root = IslandRootView(
            store: store,
            isOpen: open,
            collapsedSize: geometry.mode.isDocked ? geometry.rect.size : geometry.islandFrame.size,
            collapsedTopRadius: geometry.mode.isDocked ? NotchGeometry.expandedTopRadius : NotchGeometry.collapsedTopRadius,
            collapsedBottomRadius: geometry.cornerRadius,
            lightBorder: systemIsLight,
            onOpenSettings: { [weak self] in self?.handOff { self?.onOpenSettings?() } },
            animatesGeometry: animated
        )
        root.logoQueue = logoQueue
        root.edge = geometry.edge
        // The mode decides the silhouette, not whether there are marks to draw.
        root.hidesSilhouette = geometry.mode.isDocked
        return root
    }

    /// Run during the existing hover delay without touching the visible windows or their current shadow.
    private func prepareOpening() {
        guard case .opening = machine.state else { return }
        geometry = resolveGeometry()
        let inputs = panelInputs
        guard materialPreparation?.inputs != inputs || materialPreparation?.open != true else { return }
        let root = makeRoot(open: true, animated: false)
        let height = max(80, min(island.contentHeight(for: root).rounded(), maximumContentHeight))
        let surface = surface(open: true, height: height)
        beginMaterialPreparation(inputs: inputs, open: true, height: height, surface: surface)
    }

    private func captureMaterials(surface: Surface) -> ShadowWindowController.PreparationInputs {
        shadow.capturePreparation(geometry: geometry, island: surface.shadowIsland, islandRadius: surface.shadowRadius,
                                  casts: surface.castsShadow)
    }

    @discardableResult
    private func beginMaterialPreparation(inputs: PanelInputs, open: Bool, height: CGFloat, surface: Surface,
                                         captured: ShadowWindowController.PreparationInputs? = nil) -> MaterialPreparation {
        let captured = captured ?? captureMaterials(surface: surface)
        let render = renderMaterials
        let installed = shadow.installedPreparation(matching: captured)
        let task: Task<ShadowWindowController.PreparedImages?, Never>? = installed == nil
            ? Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return nil }
                let images = await render(captured)
                return Task.isCancelled ? nil : images
            } : nil
        let preparation = MaterialPreparation(inputs: inputs, open: open, surface: surface, height: height, task: task)
        preparation.images = installed
        materialPreparation = preparation
        guard let task else { return preparation }
        Task { [weak self, weak preparation] in
            guard let images = await task.value, let self, let preparation,
                  self.materialPreparation === preparation else { return }
            guard preparation.inputs == self.panelInputs else {
                self.apply(animated: false)
                return
            }
            preparation.images = images
            if preparation.open, case .opening(let deadline) = self.machine.state, Date() >= deadline {
                self.timerFired()
            } else if preparation.open == self.machine.isOpen {
                self.apply(animated: self.previewPlacement == nil)
            }
        }
        return preparation
    }

    func apply(animated: Bool) {
        let open = machine.isOpen
        let previousGeometry = geometry
        geometry = resolveGeometry()
        // A changed edge replaces the coordinate system; it is a repositioning, not an expansion.
        let animated = animated && geometry.edge == previousGeometry.edge
            && geometry.mode == previousGeometry.mode && geometry.screenFrame == previousGeometry.screenFrame
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var root = makeRoot(open: open, animated: animated)
        // A report can change the token chart without changing the coordinator's observed quota rows.
        // Validate at consumption as well as when the coordinator applies an update during the delay.
        let inputs = panelInputs
        var prepared = materialPreparation?.inputs == inputs && materialPreparation?.open == open ? materialPreparation : nil
        if open {
            panelHeight = prepared?.height
                ?? max(80, min(island.contentHeight(for: root).rounded(), maximumContentHeight))
        }
        let surface = surface(open: open, height: panelHeight)
        if prepared?.surface != surface { prepared = nil }
        let captured = captureMaterials(surface: surface)
        let installed = shadow.installedPreparation(matching: captured)
        let preparingFutureOpening: Bool = if case .opening = machine.state { true } else { false }
        if prepared == nil, installed == nil, !preparingFutureOpening {
            prepared = beginMaterialPreparation(inputs: inputs, open: open, height: panelHeight, surface: surface,
                                                captured: captured)
        }
        let windowFrame = surface.windowFrame
        let previousCanvas = island.panel.frame
        let previousCard = island.rootView.presentationFrame.map {
            CGRect(x: previousCanvas.minX + $0.minX, y: previousCanvas.maxY - $0.maxY,
                   width: $0.width, height: $0.height)
        }
        let cardFrame = surface.cardFrame
        if animated && previousCard != cardFrame {
            geometryTransitionFrame = cardFrame
        } else if !animated {
            geometryTransitionFrame = nil
        }

        if !animated || targetWindowFrame != windowFrame {
            targetWindowFrame = windowFrame
            if animated {
                // Every edge uses the same transition canvas. Card geometry supplies the parked anchor;
                // the union also covers a clamped card and any longer, stationary logo queue.
                island.setFrame(island.panel.frame.union(windowFrame))
            } else {
                island.setFrame(windowFrame)
            }
            island.setVisibleSize(windowFrame.size)
        }
        shadow.update(
            geometry: geometry,
            island: surface.shadowIsland,
            islandRadius: surface.shadowRadius,
            casts: surface.castsShadow,
            animated: animated,
            prepared: prepared?.images ?? installed,
            materialsPending: prepared?.images == nil && installed == nil
        )
        if !preparingFutureOpening, prepared?.images != nil || installed != nil { materialPreparation = nil }
        // The strip's place on screen is fixed; the window around it is not, so the offset between them is
        // measured rather than assumed to be the window's own top edge — which moves when the panel opens.
        let canvas = island.panel.frame
        root.logoQueueInset = max(0, canvas.maxY - geometry.rect.maxY)
        root.logoQueueHeight = geometry.rect.height
        root.logoQueueFrame = CGRect(x: geometry.rect.minX - canvas.minX,
                                     y: canvas.maxY - geometry.rect.maxY,
                                     width: geometry.rect.width, height: geometry.rect.height)
        updateClickThrough(geometry.mode.isDocked && !surface.expanded)
        // A tracking area can report an exit when the window or its hosting view resizes, even though the
        // pointer has not left the visible HUD. Both native events and the coordinator use screen geometry.
        // Collapsed logo queues pass clicks through, so their coordinator alone supplies the events.
        island.onPointerChange = geometry.mode.isDocked
            ? nil
            : { [weak self] _ in self?.samplePointer() }
        root.presentationSize = cardFrame.size
        root.presentationFrame = CGRect(x: cardFrame.minX - canvas.minX,
                                        y: canvas.maxY - cardFrame.maxY,
                                        width: cardFrame.width, height: cardFrame.height)
        root.onContentHeight = { [weak self] height in self?.updatePanelHeight(height) }
        root.onGeometryCompletion = { [weak self] in
            // Reversing or repositioning can finish an older animation together with the new one.
            // A changing logo queue can also change the canvas without changing the card's target.
            guard let self, self.geometryTransitionFrame == cardFrame,
                  let target = self.targetWindowFrame else { return }
            self.geometryTransitionFrame = nil
            self.island.setFrame(target)
        }
        island.setRootView(root)
        if geometryTransitionFrame == nil { island.setFrame(windowFrame) }
        updateDragSurface()
        prepareOpening()
    }

    /// Both preparation and presentation use the same parked edge, clamping and shadow dimensions.
    private struct Surface: Equatable {
        let windowFrame: CGRect
        let cardFrame: CGRect
        let expanded: Bool
        /// The shape the shadow falls from, in screen coordinates, and its corner.
        let shadowIsland: CGRect
        let shadowRadius: CGFloat
        /// A collapsed logo queue is its marks alone, with no shape to cast a shadow.
        let castsShadow: Bool
    }

    private func surface(open: Bool, height: CGFloat) -> Surface {
        let expanded = open && previewPlacement == nil
        let size = CGSize(width: IslandController.expandedWidth, height: height)
        // The shoulder curves widen the contact with the parked edge. Clamp their whole canvas, then
        // derive the card's core from it, so even a dock near a corner retains both curved shoulders.
        let flare = open || geometry.mode.isDocked ? NotchGeometry.expandedTopRadius : NotchGeometry.collapsedTopRadius
        let horizontal = geometry.edge.isHorizontal
        let dockWindowSize = CGSize(width: size.width + (horizontal ? flare * 2 : 0),
                                    height: size.height + (horizontal ? 0 : flare * 2))
        let cardFrame = expanded
            ? (geometry.mode.isDocked
                ? geometry.expandedFrame(size: dockWindowSize)
                : geometry.expandedFrame(size: size).insetBy(dx: -flare, dy: 0))
            : geometry.islandFrame
        // A short card must not clip a longer queue. The extra canvas stays transparent and the card
        // retains its own screen position.
        let windowFrame = open && geometry.mode.isDocked
            ? cardFrame.union(geometry.islandFrame).intersection(geometry.screenFrame)
            : cardFrame
        let islandFrame = expanded
            ? (geometry.mode.isDocked
                ? cardFrame.insetBy(dx: horizontal ? flare : 0, dy: horizontal ? 0 : flare)
                : geometry.expandedFrame(size: size))
            : geometry.rect
        let radius = open ? IslandController.expandedRadius : geometry.cornerRadius
        return Surface(windowFrame: windowFrame, cardFrame: cardFrame, expanded: expanded, shadowIsland: islandFrame,
                       shadowRadius: radius, castsShadow: expanded || !geometry.mode.isDocked)
    }
}
