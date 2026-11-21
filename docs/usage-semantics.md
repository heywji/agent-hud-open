# Usage semantics

## Overview

How Agent HUD Open counts tokens, names quota windows, colors readings, spaces account requests and keeps readings. The rules apply to every provider and to the desktop, and hosts use the same numbers. Where each client's fields come from is in [providers](providers.md); running and terminal turns are in [session lifecycle](session-lifecycle.md).

## Model

| Kind | Contains |
| --- | --- |
| Cache write | Prompt tokens written to the prompt cache |
| Input | The other new prompt tokens |
| Reasoning | Output spent reasoning or thinking |
| Output | The other output |
| Cache read | Prompt tokens read back from the cache |

The five kinds (`TokenKind`, selected as `TokenDimensions`) are additive and never overlap. Logs count cache writes inside input and reasoning inside output; a log that does not tell them apart puts everything in input and output, and so do events recorded before the ledger split them, until their logs are read again. The panel's token chart counts every kind (`all`), cache reads included, and so does its per-session token figure; `fresh` leaves cache reads out. A quota window is one row per window the service reports, with that window's own reset time and period; a reading is the last value of a window, balance or reset-credit count together with its observation time. An account is whose quota a window describes, identified by the provider's own user and workspace ids; a window's row id is the account id followed by the provider's window name (`account:<hash>/codex`).

## Rules

### Percentages, windows and presentation

- A quota row shows what is left of its window ("95% left" / "剩 95%"), as Claude Code and Codex word it, and its bar shrinks as the window is used; the burn-rate view's bar shows the share used and its projection to the reset. Providers store the remaining share.
- Rows come from the response, never from a template: `primary` is not assumed to mean 5 hours, and a window is named by the length the service gives it.
- A window's full name (`AgentDescriptor.name`) is its vendor's own words for it: the label of the vendor's usage page or client, else the phrase of its docs, in the vendor's Chinese where it publishes Chinese and in the Mac's words where it does not, such as Current session and Weekly limit · All models (Claude), 5h limit (Codex), Cursor Models, and Premium requests or AI credits (GitHub Copilot). A Kimi, GLM or OpenCode Go window is its period and then its plan, such as Weekly quota · Allegretto; the pool it belongs to names its account (`<region> · <product> · Account <id>`), not its windows. Window ids never change with a name, so switches and order stay.
- A window's short name (`AgentDescriptor.shortName`) keeps only what tells it apart from the account's other windows, with one set of period words for every provider: 5h, Daily, Weekly, Monthly and Annual (每日, 每周, 每月, 每年), any other length as its unit (3h, 30m, 3d). A model family is its name (Fable), a bucket or group that is not the account's main set is its word, with its period where it has more than one window and the English week as 7d (Spark 5h, Spark 7d, Reserve, Gemini 7d, 3rd-party 5h), and a window named by its kind is the vendor's word for it (Included, First-party, Premium, Credits). Two windows of one account whose short names would read alike show their full names, except a GLM token limit and credits of one length, which read Tokens 5h and Credits 5h. A name is never cut: a panel row shows a window's full name, and its short name only where the full name is too long for the row's fixed name column. A host shows the short name in its own tight places.
- A window is its provider's plan-wide quota (`AgentDescriptor.allModels`) unless it limits a subset of the plan's models or features: Claude's weekly window of one family, a Codex bucket other than `codex`, Cursor's Cursor Models and Other Models pools, an Antigravity group's windows where the account has several groups, GitHub Copilot's chat messages and code completions, and GLM's MCP window.
- One account's windows are shown once even when two programs share the account (Codex Desktop and CLI); usage recorded by one client is never duplicated into another client's account, and model token spend is shown separately from quota windows.
- Money keeps its currency and is never used to infer subscription quota; a separate spending budget has a percentage only when its used amount and positive limit are both known. API-billed clients (DeepSeek) show balance and estimated cost instead of windows, and estimates are labelled as estimates.
- Codex reset credits show the service's `availableCount`; the per-credit expiry list is supplementary and never derives the count.
- Before a reading exists, quota shows "—"; an observed window with an unavailable percentage shows N/A and keeps its observation and reset times. Zero is shown only when the service reported zero.
- Tokens are never converted into quota, and an unavailable quota is never inferred from token counts. Claude Code's session share (`LiveSession.pctOfWindow`) is its share of the tokens in the current 5 h window times the window's utilization, given only to sessions that spent tokens in that window.
- One API response is counted once whatever the log layout; copies of one event from two files or two Macs merge, and distinct requests with identical counts are kept. The panel's bars are 15-minute buckets on local quarter-hour boundaries inside the exact half-open range (`ChartData` also makes 30-minute, hourly and daily buckets); empty buckets keep their position and counts stay integers. A bar's hover period names its date, weekday and local time.
- A session's breakdown (`SessionUsage`, carried in `UsageReport.sessionUsage`) is read from the ledger: its own log, or its id for sources read whole, plus its sub-agents' logs: every log under the directory named like its log (Claude Code), and every rollout that names it, directly or through another sub-agent, as the thread that started it (Codex spawned agents and guardians); by kind, model, 15-minute period and turn, with the number of calls. Its totals therefore exceed the session's own counts, which leave sub-agents out and are what the panel's row shows. A session is read again when its counts move or when the ledger has changed any log it is made of, its own or a sub-agent's, since its breakdown was read.
- A turn is a prompt in the session's own log and every call, sub-agents' included, until the next prompt; calls before the first prompt form a turn of their own, a prompt no call followed forms none, and a turn notes whether the client compacted the conversation during it. Claude Code, Codex and DeepSeek Harness logs mark their prompts; sessions of other clients have no turns. A breakdown keeps the newest 200 turns and counts all of them.
- The context is a call's input with cache writes and cache reads: the session's is its latest call's, a turn's its last call's, given only for logs that record every call. The context window is the one the log reports with the call (Codex), else the model's published window; a Claude model runs with 200K or 1M, so one missing from the catalog counts as 200K until this Mac has seen it hold more.
- A consumer is named from its id alone (`ModelCatalog.consumerName(of:)`), by every provider and for any id a report does not name: the model its client logged, and the route its calls went through beside it after " · " unless the name already shows the route. A route that prefixes the model is left out of both (`kimi-code/kimi-for-coding` through `kimi-code`), a model its vendor sells under a name of its own reads as that name, without the route where the route is one of the product's own services (`kimi-for-coding` → Kimi For Coding), and a Claude Code model reads as its family and version (Opus 4.5).
- A list price (`ModelCatalog`) is what calls would cost at the vendor's published API prices, keyed by the model a call named whatever client made it: Anthropic, OpenAI, DeepSeek, xAI, Google, Zhipu, Moonshot, Alibaba, MiniMax and Xiaomi. A promotional price that lasts only a while is left out for the vendor's regular one. A gateway's name for a model (`openai/gpt-5.5`, `anthropic/claude-opus-4.6`) has no list price, since the gateway sets its own, and an OpenCode, Pi or Kimi call is priced only when the provider it names is the vendor's own API or plan, not a gateway such as OpenCode Zen, OpenCode Go or OpenRouter, a cloud such as Azure, Bedrock or Vertex, or a proxy. Input, cache writes (Claude Code's at the one-hour rate it writes with), cache reads and output with reasoning are priced at the tier the call's prompt reaches, and DeepSeek's calls in its peak hours, weekdays 9–12 and 14–18 Beijing time, at twice its off-peak rates. It is an estimate, not a charge. A session's list price is on the international list at off-peak rates, and a call whose model has no list price leaves the session without one.
- Vendors with separate China and international lists (DeepSeek, Zhipu, Moonshot, Alibaba, Xiaomi) are priced on the platform a client reaches (`PriceRegions`): its configured endpoint or plan, or for DeepSeek, which bills one platform in either currency, its account's currency. A client nothing names, or one on both platforms, is priced on the international list. Amounts keep their currency, yuan on a China list and US dollars otherwise, and add up per currency.
- `ModelCatalog.cost(of:regions:)` prices one 15-minute bucket, kind by kind in its list's currency, each model on its client's platform and DeepSeek's peak-hour buckets at its peak rates, for a host that publishes the amounts. A bucket sums calls and says nothing of any one prompt's length, so buckets are priced at the base rates, and a range can come out below its sessions where prompts ran past a tier. Models without a list price are not counted.
- The periods (`UsagePeriods`, carried in `UsageReport.periods`) are today from local midnight and the last seven and thirty days, read from the ledger, which keeps 31 days of buckets, while providers read one week of their own logs.
- The cache hit rate is cache reads against every prompt token: fresh input, cache writes and cache reads. A log that counts no cache at all has none.

### Levels

| Reading | OK | Warning | Critical |
| --- | --- | --- | --- |
| Quota window | used < 70% | used ≥ 70% | used ≥ 90% |
| DeepSeek balance in CNY | > 10 | ≤ 10 | ≤ 0 |
| DeepSeek balance in USD | > 2 | ≤ 2 | ≤ 0 |
| Balance in another currency | > 0 | — | ≤ 0 |
| Account reported unavailable | — | — | always |

- The policy is fixed (`AlertPolicy`): nothing is stored, synchronized or configurable. A color describes the resource state of one reading; readings of different windows are never combined into one health score, and a color never indicates task progress.
- `ReportView.levels` lists the level of each enabled window, and of each enabled API account, whose reading shows one, in row order; the panel colours each row and balance on its own and never combines them.
- A balance follows the rules of a quota window: after a failed read it keeps its last amount on screen without a level, and its card says why; a balance read in the future has no level either. Every currency climbs one ladder, low at its warning line where it has one and depleted at or below zero, and an account its service marks unavailable is critical whatever its balance.
- A window is exhausted with half a point or less left, for its outlook, its row and its cap statistics alike.
- A fresh 0%-used reading of a window whose reset is ahead shows quota available rather than a forecast; a missing forecast history is labelled as such, not as missing quota data.
- A window whose quota reading failed or could not be verified keeps its last reading on screen but has no level until a reading succeeds; a notice about the client's local logs or completion hooks, or about something a successful answer left out, is shown as well and holds back nothing.
- A sound reading of the current account keeps its level however old it grows, since a client nobody is using is read again only when a reset or its work calls for it. A reading dated after the Mac's clock has no level and confirms nothing.
- When every source fails to read, the last report stays on screen and every reading in it counts as failed: no window has a level, each account's header says when it was last read and the panel's first line says why, until a pass reads a source again.
- Only a reading that shows a level enters a calculation: the hover hint, and the panel row's burn rate, projection and token rate. Any other reading is shown greyed, with its known share used or N/A and its reset but without a forecast.
- Every provider reads a window's stored readings from a week back, or from the start of its current cycle when that is earlier, and counts the window's cap hits over the last week (`QuotaMath.insights`).
- The hover hint (`QuotaForecast.hint`) puts a window's outlook (`QuotaMath.outlook`) into words: how long it lasts at its pace when it runs out before its reset, and the share it will have used by the reset when it runs out only after.
- The panel row's burn rate follows the same outlook and says what the hint says, except that it gives the time a window runs out at before its reset; only a window that ran out or runs out before its reset wears the warning colour and a projection to the end of the track.
- The burn rate (`UsageAnalytics.burnRate`) is the recent pace with idle time included: consumption over the last hour of a 5h window, the last day of a weekly one and the last week of a monthly one, or over the whole observed series while that is shorter. A rise under 5 points is reading noise; a larger one is a reset and restarts the series. A series shorter than 15 minutes, or one hour for windows of a day or more, gives no estimate.

### Accounts

- Readings, quota history and display settings are keyed by the account's window rows, so two accounts of one client never share a history or a burn rate. A ChatGPT account appears once under Codex, including accounts signed in through Pi. Its latest known sign-in chooses the client that reads it; without a reliable sign-in time it keeps that confirmed client through refreshes, failed reads and restarts, while its home is still configured.
- The account of a provider's latest successful reading is current; only current accounts' readings show a level, and so enter hints and burn rates. A failed refresh keeps the current account, and a login without plan limits makes no account current.
- An account's header says it is the current account only while its readings are sound. When its own read or its client's failed or could not be verified, it says when the account was last read, and the header gives the reason beneath it, then the client's other notices; a billing pool's header speaks for its pool alone.
- Other accounts keep their last reading and its observation time, greyed under the account's name, until they have not been seen for 30 days; their readings, rows and display settings then retire. An account's visibility switch sets every associated window off or on together, preserving window order and other accounts; individual window edits do not change the account switch. Hidden accounts also keep newly discovered windows off. Quota and balance presentation follows these switches, while recorded token usage, session history and ongoing collection remain independent.
- Changing accounts is neither a reset nor an exhaustion.
- The first identified account takes over an unidentified row's position and display switch; a window that appears on a further account inherits the switch of the same window on another account. Quota history recorded before accounts were identified belongs to no account and feeds no burn rate.
- A login the provider does not identify is one account per client home directory, never merged with another home. A provider that must forget its accounts, for example after reading consent is withdrawn, retires their readings, rows and display settings at once.
- Codex reset credits belong to the account that reported them; native and Pi logins can make several accounts current at once. Billing-pool rows (Kimi, GLM, OpenCode Go) keep their pool ids as account ids, and a pool whose reading failed or whose account could not be confirmed holds back its own rows only, never another pool of the same vendor.

### Collection cadence

Reads never run in parallel: the usage store runs one pass of source reads or one account step at a time, and a pass starts only after the previous one finished. Every account request is a metadata read: no model message is sent and no reset credit is consumed.

| Work | Cadence |
| --- | --- |
| One client's local logs | When a file under its data directories changes, when one of its live sessions reaches 120 s or a running turn 120 s, 5 minutes or 30 minutes without an observation, and after its account step; passes start at most every 2 s |
| Local logs of a source that cannot name its directories | Every 5 s |
| Every client's local logs while the first index is being built | Every 2 s |
| Account readings: Claude Code engine `get_usage`, Codex `account/rateLimits/read`, DeepSeek balance, Antigravity, Cursor, Grok and GitHub Copilot quota, Cursor account usage events, and Kimi, GLM and OpenCode Go quota per billing pool | Per client: every 150 to 210 s while one of its turns runs, every 5 to 6 minutes while a session of its is live between turns, once more for work that finished since its last reading, and within a minute after one of its windows resets. Also when the panel opens or Settings → Agents → Refresh accounts is clicked, and when GitHub Copilot quota reading is switched on or off, which reads Copilot's quota at once |

- A client nobody is using is not asked: its windows move only while its own work runs. A window whose reset has passed, a reading that names no window, and a client whose usage is the account's from every device it signs in on (Cursor and Codex, including Pi logins) keep the 5-minute interval.
- A reading that follows an interval or a reset waits a random time of up to 60 s past it, drawn again after every reading, which is where the ranges above come from. Windows reset at round times, so without it every copy of the application on an account with the same reset would ask the service in the same second. The reading for work that just finished, and a reading asked for by opening the panel or by Refresh accounts, do not wait.
- A known reset takes priority over the normal cadence and stays due, from its spread past the reset, until an account request has run at or after the reset, subject to the 60-second request spacing. An old window returned after that attempt retries on the normal cadence.
- Account steps run one provider after another, back to back for at most one second before local logs get their turn, so a slow request delays a poll by that request alone.
- A pass reads only the clients that signalled; the others keep their last result. Every local source is read again every 5 minutes, which catches a change a directory watch missed. Every client's listing of its logs and databases examines only the files the watch reported changed, and lists every file again every 5 minutes or after dropped events; a listing that stops at its limit keeps the files it did not reach that are still there.
- The collector spaces account requests: a client's never repeats within 60 s, whoever asks, except GitHub Copilot's when its quota reading is switched on or off. A failure waits as long as a success; it is reported as a source notice while the other sources keep working.

### Reading retention

- The last successful reading is kept with its observation time; a failed refresh keeps it and exposes the failure, and a restart restores it before the first poll.
- A client whose read, or whose quota or balance reading, failed keeps the sessions it last reported beside those it still reports; a notice about its local logs or hooks keeps none, and neither does a billing pool's failed reading, which is no one client's.
- When a window's reset time has passed, the row keeps the last reading and its time. A reset is confirmed only by a new reading whose reset time moved forward or that shows the window full again after rising at least 5 points; until then the deadline counts as pending and the row displays “Pending update”. Historical accounts show no live countdown. Only an explicitly complete quota-window inventory from a current account with a sound reading retires omitted windows immediately from the kept report and Settings; account health alone declares no inventory. Codex rate-limit responses and Antigravity quota summaries provide this inventory, including enabled windows without new values and an empty list. An enabled window without a new value renews its presence while preserving its reading's observation time; other accounts and failed or incremental readings keep their last windows, while a notice about local logs or hooks does not hold back a complete inventory.
- Kimi, GLM and OpenCode Go rows are retired — readings, cached rows and display settings — once a completed credential scan finds their credentials expired, removed or rejected; a temporary network failure retires nothing.
- A row no provider has reported for 30 days retires with its reading, whatever stopped it: a client uninstalled, a window the service dropped, a vendor no longer read. Until a provider reports a row it is not shown anywhere, and its stored display switch and position wait for it.
- One rule (`ReportView.isPresent`) decides whether a row is present in the panel, Settings and the report kept across passes: a provider reported it within 30 days, its account is in its provider's inventory, and its plan pool is active. What no report says counts as present, so before the first read every row shows, plan pools included, and a row without an account leaves once its provider identifies accounts.
- Settings keeps a group for every source supplied by the host, including clients not detected on this Mac. Undetected-source groups follow all other groups without changing relative order within either section; groups without source metadata remain in the first section. A source group creates no quota windows or accounts, existing windows keep their manual order, and reported services remain available.
- Quota histories keep 30 days, and an API balance's readings one day, for its trend (`BalanceTrend`): the time it runs out at the pace it fell since the first of that day's readings, or since its latest rise, a top-up. Readings spanning less than three hours, a balance that did not fall and one at or below zero give no estimate; each balance carries its estimate as of its reading (`AccountBalance.runsOutAt`).
- A session whose source never says what its turn is doing leaves the running indicator 120 s after its last observation; one whose source reports a running turn keeps it until the turn ends, or until 30 minutes without an observation say its client is gone. Either way it stays in history without an invented end time.

## Code map

| Concept | Code |
| --- | --- |
| Token kinds and dimensions, bar buckets | `Sources/AgentHUDCore/Models/Usage/TokenKinds.swift`, `Sources/AgentHUDCore/Logic/ChartData.swift` |
| List prices, platforms, context windows | `Sources/AgentHUDCore/Models/Catalog/ModelCatalog.swift`, `ModelPriceList.swift`, `PriceRegions.swift` |
| Today, seven and thirty days | `Sources/AgentHUDCore/Models/Usage/UsagePeriods.swift`, `Ledger/UsageLedger.swift` |
| Levels, thresholds and reading age, status colors | `Sources/AgentHUDCore/Logic/Alerts/AlertPolicy.swift`, `StatusLevel.swift`; `Sources/AgentHUDDesktop/Theme/StatusPalette.swift` |
| Reading status and assessment | `Sources/AgentHUDCore/Models/Accounts/ReadingStatus.swift` |
| Which rows are present, levels and hints | `Sources/AgentHUDCore/Logic/ReportView.swift` |
| Forecast hint | `Sources/AgentHUDCore/Logic/Quota/QuotaForecast.swift` |
| Event union, analytics, history retention | `Sources/AgentHUDCore/Providers/Kit/UsageAggregation.swift`, `Ledger/QuotaHistoryStore.swift`, `Logic/Quota/UsageAnalytics.swift` |
| A window's remaining share, insights, outlook, projection and token rate | `Sources/AgentHUDCore/Logic/Quota/QuotaMath.swift` |
| Window names: full and short names, period words | `Sources/AgentHUDCore/Formatting/WindowNames.swift`, `Localization.swift`, `Models/Agents/AgentDescriptor.swift`; each provider's reader |
| A balance's trend | `Sources/AgentHUDCore/Logic/Quota/BalanceTrend.swift`, `Ledger/BalanceSample.swift` |
| Session liveness and its limits, retained readings | `Sources/AgentHUDCore/Logic/SessionPhase.swift`, `Sources/AgentHUDCore/Models/Sessions/LiveSession.swift`, `Sources/AgentHUDCore/Providers/RetainedUsageProvider.swift` |
| Session breakdown | `Sources/AgentHUDCore/Models/Sessions/SessionUsage.swift`, `Ledger/UsageLedger.swift`, `Providers/CombinedUsageProvider.swift` |
| Accounts, current and previous readings, settings migration | `Sources/AgentHUDCore/Models/Accounts/ProviderAccount.swift`, `Providers/Kit/ClientHome.swift`, `Sources/AgentHUDCore/Providers/RetainedUsageProvider.swift`, `Sources/AgentHUDCore/Store/SettingsStore.swift` |

## Related

[providers.md](providers.md) per-client fields and request intervals · [session-lifecycle.md](session-lifecycle.md) running and terminal turns · [architecture.md](architecture.md) design invariants
