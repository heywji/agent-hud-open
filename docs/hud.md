# The HUD on screen

## Overview

Each display has its own HUD and settings. Notch mode uses the physical notch or a stand-in bar; Dynamic mode places agent logos along any screen edge, bare, with nothing behind them; Off leaves a display without a HUD. Hovering opens the panel, the board: quota windows, API balances, the last 24 hours of tokens and the recent sessions. The open panel and the notch cast a drop shadow.

## Model

| Concept | Meaning |
|---|---|
| HUD | One display's presentation: a collapsed entry on a screen edge, the panel it opens into, and its shadow |
| Notch mode | The island: the physical notch on a Mac that has one, or a bar standing in for it on a display that does not |
| Dynamic mode | A queue of marks — the watched vendors and any run in the last day — along a screen edge with no shape behind them |
| Off | No HUD on the display; with every display off, the main display keeps one |
| Panel | The board the HUD opens into: quota windows, balances, the token chart and the session summary, above a footer with Settings and Quit |
| Shadow | A blurred drop shadow under the notch and every open panel, drawn in a click-through window of its own |
| Placement | What one display shows and where: mode, edge, position along the edge, logo size, logo spacing, the logos' distance from the edge and whether they are drawn |

## Rules

### Placement

- A display with a notch defaults to notch mode; a display without one defaults to Dynamic mode, so no screen draws a bar pretending to have a notch.
- Any mode can be chosen for any display; notch mode stays at the physical notch or the screen's top centre. Choosing Dynamic in settings for a display with a notch moves a HUD still at top centre to the top left, clear of the hardware.
- A display keeps its own placement under its UUID; display settings can reset its position to top centre, or top left for a dock on a notched display, keeping its mode and logo settings.
- Off removes a display's HUD. With every display off, the main display keeps its HUD, since its panel is the way into Settings.
- The dock can sit anywhere along the top, right, bottom or left edge, running horizontally on the top and bottom and vertically on the sides; logo size is 12–36 pt, spacing is 0.1–0.6 of the logo, and the logos stand 0–20 pt in from the edge.
- Drag a visible HUD directly to any edge; dragging a notch switches it to Dynamic mode. A press picks the HUD up after 6 pt of travel or 0.3 s held still, and its dashed bounds appear then; dropping it moves it without opening the panel.
- The marks can be hidden, which keeps the queue's place and width: hovering there still opens the panel, but nothing can be grabbed and clicks pass through.

### What the queue shows

- The enabled, non-API-billed agents first, in the order they are watched in, then any vendor that ran in the last day without a window on that list, most recently used first.
- Watched vendors appear before their first reading; vendors shown only for recent activity leave a day after their last turn and never appear with Live status off.
- Shared artwork appears once: Claude windows share one mark, as do Codex and ChatGPT. Grok's shared account rows show its recently used clients' marks, or the Grok mark when none ran.
- A dock with nothing to show keeps a minimal entry at its saved position without drawing a logo.
- Marks retain their artwork with a hairline outline; single-colour marks are white, and a two-variant mark uses its dark variant. A mark looks the same whether its agent works or not, and nothing in the queue moves.

### Hovering

- A visible dock accepts dragging; with logos hidden, clicks pass through.
- Hovering opens the panel inward after the hover delay and closes it after the collapse delay, with the same timing on all four edges. With Press Option to open, hovering alone leaves the panel closed: a tap of Option while hovering starts the hover, which then counts until the pointer leaves, and an open panel needs no Option. With Open immediately at the top edge, a pointer that reaches the screen's top edge directly above a top-edge HUD skips the delay.
- During the delay, content height is measured and the shadow bitmap is drawn off the main thread without retaining a hidden panel; leaving cancels preparation and discards late results. Opening and collapse commit their window geometry immediately, with the shadow installed when ready. A matching installed shadow is reused without another raster.
- Opening the panel reads every account again, within each provider's request spacing ([cadence](usage-semantics.md#collection-cadence)).
- Settings in the footer collapses the HUD before opening its window, and the panel opens again only once the pointer has left and returned. Quit ends the application.
- A dock's open panel flares outward at both ends of its contact with the parked edge, while its content stays upright; the marks keep their saved position over the open panel, even when its content is shorter than the queue.
- A collapsed dock casts no shadow; the notch's silhouette and every open panel do.
- Reduce Motion drops the geometry animation: the panel takes its new size at once.

### The panel

- It shows, from the top: the error of the last refresh when it failed; each vendor's quota windows; the API balance cards; the token chart; the session summary. Display settings switch the quota windows with the balances, the reset countdowns, the token chart and the session list.
- It is 540 pt wide. Height follows content between 80 pt and the display's height minus 80 pt; overflow scrolls above the fixed footer, Settings (gear) on the left and Quit (power) on the right, clear of the notch and dock.
- A vendor's block is headed by its mark and name and groups its windows by account, under the account's header where it has one: the account's name and plan, whether it is current or when it was last read, and why a reading failed. Another account's rows are dimmed. Showing the share left, a row's marker and figure take its level colour ([levels](usage-semantics.md#levels)); a reading without a level is grey.
- Each block has a picker for what its rows show: the share left (percent sign), the burn rate (flame) or tokens per hour (number sign). The choice is the block's own and survives refreshes. Hovering a row that has an outlook shows it in words ([usage semantics](usage-semantics.md)).
- A Codex account lists its available usage resets beneath its windows, with their expiry on hover; an account with a wallet, as Grok's has, lists its prepaid and on-demand amounts.
- An API billed by use has a card of its own: its balance in the balance's level colour, and the estimated cost of the last 24 hours, the day the token chart shows. A balance whose read failed keeps its last amount without a colour and says why.
- The token chart holds the latest 24 hours in 96 quarter-hour bars, including the current quarter, every model stacked in its colour and every token kind counted, with the 24-hour total in its header. Hovering a bar shows its period, its total and each model's tokens.
- The session summary has at most five rows: sessions with work in flight, those waiting for the user ahead of those still running and newest created first within each group, then sessions last active in the past 24 hours by their last event. "+N more" counts the rest of that summary; account-wide API receipts never enter it. The header says how many are running, or Recently ended.
- A row shows its agent's mark with the session's state on its corner — the agent's colour while it runs, the warning colour while it waits for approval, grey once ended — then a shortened title with the workspace folder, or the whole title where the session names no folder, and its tokens, cache reads included. Hovering shows the whole title. Rows are not clickable.

## Interfaces and configuration

| Setting | Values | Default |
|---|---|---|
| `screens[<display UUID>].mode` | `notch`, `logos` (Dynamic), `off`; a stored mode this build lacks, such as `simple`, reads as `logos` | By hardware: `notch` with a notch, `logos` without |
| `screens[…].edge` / `offset` | `top`, `right`, `bottom`, `left` / 0–1 along the edge | `top` / 0.5 |
| `screens[…].logoSize` / `gapScale` | 12–36 pt / 0.1–0.6 of the logo | 20 pt / 0.4 |
| `screens[…].logoEdgeDistance` | 0–20 pt from the visible logo, outline included, to its edge | 2 pt |
| `screens[…].showsLogos` | Draw the marks, or keep their place empty | `true` |
| `requiresOptionToOpen` | Hovering alone leaves the panel closed | `false` |
| `openImmediatelyAtTop` | Reaching the top edge above the HUD skips the hover delay | `false` |
| `hoverDelayMs` / `collapseDelayMs` | 0–1500 ms in Settings | 400 / 200 |
| `showIslandQuota` / `showIslandTokens` / `showIslandSessions` | The panel's quota windows and balances / token chart / session summary | `true` |
| `showResetCountdown` | Reset countdowns beside the windows, and the expiry of Codex usage resets | `true` |
| `clientHooks` | Keep Agent HUD's handlers in the clients' own settings ([session lifecycle](session-lifecycle.md)) | `true` |

Settings saved by a fuller build decode without their glow, bot, approval-wait and menu bar fields, and a screen's Simple and Separate agents fields are ignored.

`Settings.placement(on:hasNotch:)` answers what one display uses, falling back to the default when it has none of its own. It is keyed by the string `ScreenIdentity.key(for:)` returns for a display.

## Code map

| Concept | Where |
|---|---|
| Per-display placement | `Sources/AgentHUDCore/Models/Settings/ScreenPlacement.swift`, `Settings.swift` |
| One HUD per screen, and what they share | `Sources/AgentHUDDesktop/Notch/ScreenHUD.swift`, `ScreenIdentity.swift`, `Notch/Island/IslandController.swift` |
| Where a HUD sits on its screen | `Sources/AgentHUDDesktop/Notch/NotchGeometry.swift` |
| Hover timing | `Sources/AgentHUDDesktop/Notch/HoverMachine.swift` |
| Which vendors the queue shows, and the marks | `Sources/AgentHUDCore/Logic/ReportView.swift`; `Sources/AgentHUDDesktop/Notch/Island/LogoQueueView.swift`, `LogoImages.swift` |
| Collapsed shape and panel | `Sources/AgentHUDDesktop/Notch/Island/IslandRootView.swift`, `IslandWindowController.swift`, `IslandShape.swift` |
| The panel: quota blocks, balances, token chart, sessions, footer | `Sources/AgentHUDDesktop/Notch/Panel/HoverPanelView.swift`, `ProviderQuotaBlock.swift`, `ModelUsageRow.swift`, `APIBillingCard.swift`, `TokenChart.swift` |
| The shadow | `Sources/AgentHUDDesktop/Notch/ShadowWindowController.swift` |
| Dragging | `Sources/AgentHUDDesktop/Notch/Island/HUDDragWindowController.swift` |
| Settings for all of it | `Sources/AgentHUDDesktop/Settings/ScreensPane.swift`, `IslandPane.swift`, `DisplayPane.swift` |

## Related

[architecture.md](architecture.md) package layout and host integration · [usage-semantics.md](usage-semantics.md) what the levels behind the colours mean · [session-lifecycle.md](session-lifecycle.md) when a session counts as live · [command-line.md](command-line.md) launch options
