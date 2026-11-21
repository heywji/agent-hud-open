import Foundation

public enum AppearanceMode: String, Codable, Sendable, CaseIterable {
        case system
        case dark
        case light
}

/// User-tunable settings. Every field has a default so older stored JSON still decodes.
public struct Settings: Hashable, Codable, Sendable {
    /// Hovering alone opens the panel. With this on it takes Option as well, so a HUD parked over the menu
    /// bar or a window's title bar does not open every time the pointer crosses it.
    public var requiresOptionToOpen: Bool = false
    /// Reaching the display's top edge above the HUD skips the hover delay.
    public var openImmediatelyAtTop: Bool = false
    public var hoverDelayMs: Int = 400
    public var collapseDelayMs: Int = 200
    public var showResetCountdown: Bool = true
    public var showIslandQuota: Bool = true
    public var showIslandTokens: Bool = true
    public var showIslandSessions: Bool = true
    /// Accounts hidden from quota and balance presentation. Their recorded usage stays intact.
    public private(set) var hiddenAccountIDs: Set<String> = []
    /// Saved live-status choices, including the initial choice based on whether a client was detected.
    /// Collection, session history and token accounting are independent of this preference.
    public private(set) var liveStatusPreferences: [String: Bool] = [:]
    /// Agent vendors whose live status is excluded from presentation.
    public var disabledLiveStatusSources: Set<String> {
        Set(liveStatusPreferences.filter { !$0.value }.map(\.key))
    }
    /// Querying GitHub Copilot quota reads the GitHub CLI sign-in, so it stays off until the user agrees.
    public var readCopilotQuota: Bool = false
    /// Whether Agent HUD keeps its handlers in the clients' own settings: Claude Code's notification hook, the stop
    /// hooks and the OpenCode and Pi observers, which tell the panel when a session waits or its turn ended. Off, they
    /// are removed and never added back.
    public var clientHooks: Bool = true
    public var launchAtLogin: Bool = true
    public var appearance: AppearanceMode = .system
    public var language: AppLanguage = .system
    /// Per-screen HUD placement, keyed by the display's stable UUID. A screen missing from the map takes
    /// `ScreenPlacement.default(hasNotch:)` for its hardware, so a newly attached display needs no setup.
    public var screens: [String: ScreenPlacement] = [:]

    /// This screen's placement, or the default its hardware deserves, resolved in one place so a caller cannot
    /// invent its own fallback.
    public func placement(on screen: String, hasNotch: Bool) -> ScreenPlacement {
        screens[screen] ?? .default(hasNotch: hasNotch)
    }

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case requiresOptionToOpen, openImmediatelyAtTop, hoverDelayMs, collapseDelayMs, showResetCountdown
        case showIslandQuota, showIslandTokens, showIslandSessions, hiddenAccountIDs
        case liveStatusPreferences, disabledLiveStatusSources, readCopilotQuota, clientHooks
        case launchAtLogin, appearance, language, screens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        requiresOptionToOpen = try c.decodeIfPresent(Bool.self, forKey: .requiresOptionToOpen) ?? d.requiresOptionToOpen
        openImmediatelyAtTop = try c.decodeIfPresent(Bool.self, forKey: .openImmediatelyAtTop) ?? d.openImmediatelyAtTop
        hoverDelayMs = try c.decodeIfPresent(Int.self, forKey: .hoverDelayMs) ?? d.hoverDelayMs
        collapseDelayMs = try c.decodeIfPresent(Int.self, forKey: .collapseDelayMs) ?? d.collapseDelayMs
        showResetCountdown = try c.decodeIfPresent(Bool.self, forKey: .showResetCountdown) ?? d.showResetCountdown
        showIslandQuota = try c.decodeIfPresent(Bool.self, forKey: .showIslandQuota) ?? d.showIslandQuota
        showIslandTokens = try c.decodeIfPresent(Bool.self, forKey: .showIslandTokens) ?? d.showIslandTokens
        showIslandSessions = try c.decodeIfPresent(Bool.self, forKey: .showIslandSessions) ?? d.showIslandSessions
        hiddenAccountIDs = Set(try c.decodeIfPresent([String].self, forKey: .hiddenAccountIDs) ?? [])
        if let saved = try c.decodeIfPresent([String: Bool].self, forKey: .liveStatusPreferences) {
            liveStatusPreferences = saved.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        } else {
            // Older settings recorded only disabled clients; enabled clients had no saved choice.
            for vendor in try c.decodeIfPresent([String].self, forKey: .disabledLiveStatusSources) ?? [] {
                liveStatusPreferences[vendor.lowercased()] = false
            }
        }
        // The former Grok switch belonged to the CLI. Keep one stored choice after clients split.
        if let legacy = liveStatusPreferences.removeValue(forKey: "grok"), liveStatusPreferences["grok cli"] == nil {
            liveStatusPreferences["grok cli"] = legacy
        }
        readCopilotQuota = try c.decodeIfPresent(Bool.self, forKey: .readCopilotQuota) ?? d.readCopilotQuota
        clientHooks = try c.decodeIfPresent(Bool.self, forKey: .clientHooks) ?? d.clientHooks
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        appearance = try c.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? d.appearance
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? d.language
        screens = (try? c.decodeIfPresent([String: ScreenPlacement].self, forKey: .screens)) ?? d.screens
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requiresOptionToOpen, forKey: .requiresOptionToOpen)
        try c.encode(openImmediatelyAtTop, forKey: .openImmediatelyAtTop)
        try c.encode(hoverDelayMs, forKey: .hoverDelayMs)
        try c.encode(collapseDelayMs, forKey: .collapseDelayMs)
        try c.encode(showResetCountdown, forKey: .showResetCountdown)
        try c.encode(showIslandQuota, forKey: .showIslandQuota)
        try c.encode(showIslandTokens, forKey: .showIslandTokens)
        try c.encode(showIslandSessions, forKey: .showIslandSessions)
        try c.encode(hiddenAccountIDs.sorted(), forKey: .hiddenAccountIDs)
        try c.encode(liveStatusPreferences, forKey: .liveStatusPreferences)
        try c.encode(readCopilotQuota, forKey: .readCopilotQuota)
        try c.encode(clientHooks, forKey: .clientHooks)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(language, forKey: .language)
        try c.encode(screens, forKey: .screens)
    }

    /// Functional update helper so call sites read as `settings.with { $0.hoverDelayMs = 300 }`.
    public func with(_ change: (inout Settings) -> Void) -> Settings {
        var copy = self
        change(&copy)
        return copy
    }

    public var hoverDelay: TimeInterval { Double(hoverDelayMs) / 1000 }
    public var collapseDelay: TimeInterval { Double(collapseDelayMs) / 1000 }

    /// Rows without an account retain their existing window switch.
    public func accountVisible(_ id: String?) -> Bool {
        id.map { !hiddenAccountIDs.contains($0) } ?? true
    }

    public mutating func setAccountVisibility(id: String, visible: Bool) {
        if visible { hiddenAccountIDs.remove(id) }
        else { hiddenAccountIDs.insert(id) }
    }

    public func liveStatusEnabled(for vendor: String) -> Bool {
        liveStatusPreferences[Self.liveStatusKey(vendor)] ?? true
    }

    public mutating func setLiveStatus(for vendor: String, enabled: Bool) {
        liveStatusPreferences[Self.liveStatusKey(vendor)] = enabled
    }

    private static func liveStatusKey(_ vendor: String) -> String {
        let key = vendor.lowercased()
        return key == "grok" ? "grok cli" : key
    }

    /// A client not detected on this Mac starts with live status off. A later detection never overrides a saved choice.
    public mutating func applyLiveStatusDefaults(sources: [SourceStatus]) {
        for source in sources where SessionSource.agentVendors.contains(source.name) {
            let vendor = source.name.lowercased()
            if liveStatusPreferences[vendor] == nil {
                liveStatusPreferences[vendor] = source.supportsLiveStatus && source.state != .notDetected
            }
        }
    }
}
