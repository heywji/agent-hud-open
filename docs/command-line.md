# Command line

## Overview

Launch options, read-only probes and adapter commands of the standalone application. The same switches work on `build/Agent HUD Open.app/Contents/MacOS/Agent HUD Open` (after `make build`), on `swift run AgentHUDOpen`, and through Launch Services as `open "build/Agent HUD Open.app" --args …`. Unknown switches are ignored; probes and adapter commands run before the application object exists and never show a window. Applications that embed the libraries document their own parameters.

## Launch and display

| Switch | Effect |
| --- | --- |
| `--lang zh\|en\|system` | Force the interface language for this launch (`zh`, `zh-hans` and `cn` select Simplified Chinese). The choice is saved to the preferences. |
| `--show-settings` | Open the settings window after start. |
| `--open-panel` | Start with the panel open, on the display the pointer is on. |
| `--reset-defaults` | Remove the application's stored preferences before starting. |

Only one Agent HUD runs at a time, whichever application built on these libraries it is. A launch while another copy runs shows an alert naming the application that runs and quits before it reads preferences, opens the ledger or touches a client's settings. The lock is `~/Library/Caches/app.agenthud/instance.lock`, released by the system when its holder quits or crashes; a lock that cannot be created lets the launch run. Probes and adapter commands run beside the running copy; a launch with `--reset-defaults` does not, since the preferences it removes may be in use.

## Read-only probes

| Command | Output |
| --- | --- |
| `--probe` | Prints where Claude Code's engine, Codex's engine and home, DeepSeek Harness's home and Node.js are, the agents in the settings and one step of reading Claude Code's transcripts; then one real account refresh (48 h of history) and one report with how long each took, `Quota windows: n; sessions: n; live: n; billing accounts: n`, the plans and notice, the discovered rows, each window's share used and reset, sessions by client, DeepSeek Harness's sessions and tokens, each balance and its estimated cost, the five newest sessions with their tokens and the values the vendor catalog does not name. Exits 0, or prints the error and exits 1. It issues the same provider requests as the running application and nothing else, and keeps what it reads in memory: it writes nothing to the usage ledger, removes or imports no earlier version's files and remembers no account identity. No conversation text and no credential is printed. |
| `--probe-open-agents` | Indexes the last seven days of local OpenCode, Kimi and Pi sessions and prints, per client, the session count, running count, distinct usage events, In / Out / Cache totals and the read status. No network requests, no transcript text, no credentials in the output. |
| `AGENT_HUD_PROBE_ADDITIONAL=1 swift test --filter AdditionalProviderTests/testInstalledSourcesReadOnlyProbe` | Read-only probe of the installed Antigravity, Cursor and Grok sources from the test suite; the test is skipped unless the variable is set. |
| `AGENT_HUD_PROBE_GROK=1 swift test --filter AdditionalProviderTests/testInstalledGrokLocalUsageReadOnlyProbe` | Local Grok token totals after merging inference and completed-turn logs, alongside turn-log totals. No network requests or conversation text; skipped unless enabled. |

## Adapter commands

| Command | Effect |
| --- | --- |
| `--install-pi-observer` | Write or update the Agent HUD extension `extensions/agent-hud.ts` under the Pi directory (`PI_CODING_AGENT_DIR`, default `~/.pi/agent`), then exit. Existing Pi sessions need `/reload` once. A same-named file that is not Agent HUD's is left alone and the command fails. |
| `--attention-hook claude` | The handler Claude Code invokes for a notification: reads the payload from standard input, records the session's pending request, prints `{}` and exits 0 even when recording fails. |
| `--install-completion-hook copilot` | Point GitHub Copilot CLI's stop hook at this executable, adding it when it is missing; an Agent HUD handler already there, whichever copy wrote it, is taken over. Other hooks in the client's configuration are preserved. Fails, changing nothing, when this executable runs from a disk image or a translocated copy. `antigravity`, `cursor`, `codebuddy` and `qwen` fail too, changing nothing: this build does not use their stop hooks. |
| `--completion-hook antigravity\|cursor\|copilot\|codebuddy\|qwen` | The handler the clients invoke: reads the hook payload from standard input, stores a completion record when the payload describes a successful stop, prints `{"decision":"stop"}` for Antigravity or `{}` for the others, and exits 0 even when recording fails. It never initializes the interface or queries an account. Only Copilot's is installed; for the others it answers a handler a fuller build left behind until the next start takes that handler out. |
| `--permission-hook <client>` | Retired: the handler fuller builds installed to answer permission requests on the HUD. Prints nothing, which leaves the client's own permission prompt, and exits 0, whatever client it names, without reading the payload, initializing the interface or querying an account ([retired handlers](session-lifecycle.md#retired-handlers)). |
| `--session-origin-hook <client>` | Retired: the handler fuller builds installed to find a session's terminal. Prints `{}` and exits 0 the same way. |

Normal start-up already runs `SessionObservers.configure(executable:enabled:)` for installed clients with the `clientHooks` setting — pointing every Agent HUD handler at this executable when it is on, whichever copy wrote it, and removing them all when it is off — which also installs Claude Code's notification hook and GitHub Copilot CLI's stop hook, and, either way, takes Agent HUD's stop hooks out of Antigravity, Cursor, CodeBuddy and Qwen Code and the retired handlers that run this executable out of every client. Moving the application, or starting another build of it, therefore moves the hooks at the next start. The install commands exist for a first setup without launching the application ([notification hook](session-lifecycle.md#notification-hook), [completion hooks](session-lifecycle.md#completion-hooks)).

## Environment

| Variable | Meaning |
| --- | --- |
| `SWIFT_SCRATCH_PATH` | Passed to `swift build` as `--scratch-path` by the build script |
| `AGENT_HUD_PROBE_ADDITIONAL`, `AGENT_HUD_PROBE_GROK` | Enable the read-only probe tests above |
| Client home overrides and provider keys (`CODEX_HOME`, `DSH_HOME`, `PI_CODING_AGENT_DIR`, …) | Read from the process environment ([providers](providers.md)); a directory variable that is empty or only whitespace counts as unset. An application started from Finder or Launch Services inherits the login session's environment, not the exports of a terminal shell. |

## Code map

| Concept | Code |
| --- | --- |
| Switch parsing | `Sources/AgentHUDDesktop/App/LaunchOptions.swift` |
| One copy at a time | `Sources/AgentHUDCore/System/InstanceLock.swift`, `Sources/AgentHUDDesktop/App/SingleInstance.swift` |
| Adapter commands, hook handlers and retired handlers | `Sources/AgentHUDCore/Hooks/HookEntry.swift`, `RetiredHooks.swift` |
| Probes | `Sources/AgentHUDCore/Store/UsageProbe.swift`, `Sources/AgentHUDOpenApp/main.swift` |
| Real-window interaction tests | `Tests/AgentHUDDesktopTests/Notch/Island/IslandAnimationTests.swift`, `IslandHoverTests.swift`, `Settings/AgentSettingsInteractionTests.swift` |
| Build script and targets | `scripts/build-app.sh`, `Makefile` |

## Related

[session-lifecycle.md](session-lifecycle.md) completion hooks, retired handlers and the observers · [providers.md](providers.md) per-client environment variables · [architecture.md](architecture.md) host integration
