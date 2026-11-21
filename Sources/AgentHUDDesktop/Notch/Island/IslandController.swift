import AppKit
import AgentHUDCore
import SwiftUI

/// Owns one `ScreenHUD` per display and everything they share.
///
/// A HUD belongs to a screen: two displays can run different modes, be hovered independently and show
/// different things. What cannot be split lives here — the store and settings they all read, the system
/// appearance and the pointer.
@MainActor
final class IslandController {
    static let expandedWidth: CGFloat = 540
    static let defaultPanelHeight: CGFloat = 326
    static let expandedRadius: CGFloat = 26

    private let store: UsageStore
    private let settings: SettingsStore
    private(set) var huds: [String: ScreenHUD] = [:]
    /// Display order, so the primary HUD is stable rather than whatever the dictionary yields.
    private var order: [String] = []
    private var systemIsLight = SystemAppearance.isLight
    private var observers: [Any] = []
    private var pointerMonitors: [Any] = []

    var onOpenSettings: (() -> Void)? { didSet { huds.values.forEach { $0.onOpenSettings = onOpenSettings } } }

    init(store: UsageStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
        rebuild()

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.systemIsLight = SystemAppearance.isLight
                self.huds.values.forEach { $0.systemIsLight = self.systemIsLight }
                self.apply(animated: false)
            }
        })
        trackChanges({ [weak self] in self?.inputs }, onChange: { [weak self] in
            self?.apply(animated: true)
        })
        startPointerMonitors()
    }

    /// What every HUD's frame is computed from. Session liveness reads the store's clock, which ticks every ten
    /// seconds, so the values are compared and a tick that changes none of them leaves the HUDs alone; the panel's
    /// countdowns observe the clock themselves.
    private struct Inputs: Equatable {
        let rows: [AgentRow]
        let sessions: [LiveSession]
        /// The marks a logo queue holds.
        let vendors: [String]
        let settings: AgentHUDCore.Settings
        let agents: [AgentDescriptor]
    }

    private var inputs: Inputs {
        Inputs(rows: store.rows, sessions: store.sessions, vendors: store.queueVendors.map(\.vendor),
               settings: settings.settings, agents: settings.agents)
    }

    // MARK: Screens

    /// Builds a HUD for every attached display and drops the ones whose display is gone. A machine with no
    /// screen at all still gets one, so the app has somewhere to draw the moment a display appears.
    private func rebuild() {
        ScreenIdentity.forgetKeys()
        let screens = shownScreens
        rebuild(keys: screens.isEmpty ? ["screen:none"] : screens.map { ScreenIdentity.key(for: $0) }, screens: screens)
    }

    /// One HUD per key, in display order; `screens` holds the display behind each key that has one.
    func rebuild(keys: [String], screens: [NSScreen]) {
        for key in huds.keys where !keys.contains(key) {
            huds.removeValue(forKey: key)?.close()
        }
        for (index, key) in keys.enumerated() where huds[key] == nil {
            let hud = ScreenHUD(key: key, screen: screens.indices.contains(index) ? screens[index] : nil,
                                store: store, settings: settings)
            hud.systemIsLight = systemIsLight
            hud.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
            huds[key] = hud
        }
        order = keys
        huds.values.forEach { $0.apply(animated: false) }
    }

    /// The displays that get a HUD: every one not switched off. With all of them off the main display keeps
    /// its HUD anyway, since its panel is the way into Settings.
    private var shownScreens: [NSScreen] {
        let screens = NSScreen.screens
        let shown = screens.filter { settings.settings.screens[ScreenIdentity.key(for: $0)]?.mode != .off }
        if shown.isEmpty, let main = NSScreen.main ?? screens.first { return [main] }
        return shown
    }

    /// The HUD the tests act on when no screen is named: the main display's.
    var primary: ScreenHUD? {
        NSScreen.main.map { ScreenIdentity.key(for: $0) }.flatMap { huds[$0] } ?? order.first.flatMap { huds[$0] }
    }

    /// The HUD on the screen the pointer is on, which is the one hover acts on.
    private var underPointer: ScreenHUD? {
        let point = NSEvent.mouseLocation
        let key = NSScreen.screens.first { $0.frame.contains(point) }.map { ScreenIdentity.key(for: $0) }
        return key.flatMap { huds[$0] } ?? primary
    }

    var island: IslandWindowController { primary!.island }
    var shadow: ShadowWindowController { primary!.shadow }
    var geometry: NotchGeometry { primary!.geometry }

    // MARK: Pointer

    /// One monitor for every screen. A collapsed logo queue takes no mouse events so that clicks pass
    /// through it, which also costs it its tracking; this is what tells each HUD where the pointer is.
    private func startPointerMonitors() {
        let matching: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: matching, handler: { [weak self] _ in
            Task { @MainActor in self?.huds.values.forEach { $0.samplePointer() } }
        }) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: matching, handler: { [weak self] event in
            Task { @MainActor in self?.huds.values.forEach { $0.samplePointer() } }
            return event
        }) {
            pointerMonitors.append(local)
        }
    }

    // MARK: Forwarding

    func apply(animated: Bool) {
        // Switching a display off or back on changes which HUDs exist, not just how they look.
        let keys = shownScreens.map { ScreenIdentity.key(for: $0) }
        if !keys.isEmpty, keys != order { return rebuild() }
        huds.values.forEach { $0.apply(animated: animated) }
    }

    func forceOpen() { underPointer?.forceOpen() }

    func forceCollapse() { huds.values.forEach { $0.forceCollapse() } }

    func pointer(inside: Bool) { underPointer?.pointer(inside: inside) }
}
