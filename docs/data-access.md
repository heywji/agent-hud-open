# Data access

## Overview

Agent HUD Open reads agent activity and usage metadata on your Mac. It has no Agent HUD account, cloud synchronization or push service. Building it requires no developer account, product credential, provisioning profile or signing certificate; local builds use ad-hoc signing.

## Providers

| Client | Local data | Quota or balance queries |
| --- | --- | --- |
| Claude Code | Session records and account profile | Installed Claude engine usage interface |
| Codex Desktop / CLI | Session records and sign-in time, including `CODEX_HOME` | Installed Codex app-server account rate limits |
| DeepSeek Harness | Session records and profile-owning Node process metadata, including `DSH_HOME` | Official DeepSeek balance endpoint with the configured Harness API key, which Harness's own credentials package resolves inside a short-lived Node helper |
| Antigravity | The process list (`ps`) and the listening port of the running language server (`lsof`), whose command line holds its local token, looked up at most every 10 seconds and at once when the server stops answering; conversation metadata | A local `POST` to that language server on 127.0.0.1 |
| Cursor | Local application database and session metadata | Official Cursor usage endpoints with the installed client's session token; for an account that runs Grok Bot, Cursor's Grok Bot service for the routines of the rostered bots, with the same token |
| Grok CLI | Local session records and credential file | Official Grok CLI billing endpoint |
| OpenCode, Kimi, GLM, Pi | Local JSON/SQLite session records and supported provider configuration, including an `ANTHROPIC_BASE_URL` and its token from the environment or Claude Code's `settings.json` `env` that point at a Kimi or GLM plan; automatically prepared Pi lifecycle observer and OpenCode completion plugin | Official Kimi, GLM, OpenCode Go, and Pi ChatGPT quota endpoints where configured |
| GitHub Copilot CLI | Local session events and OpenTelemetry export files | GitHub Copilot quota endpoint with the GitHub CLI sign-in, only after consent in Settings |
| OpenClaw, Hermes Agent, ZCode, CodeBuddy, WorkBuddy, Qwen Code | Local session databases and transcripts | None |
| Qoder, Qoder CN, QoderWork | Nothing read; a retired approval handler of this copy is taken out of each build's settings | None |

Per-client fields, endpoints and stored data: [providers](providers.md). Token counts, percentages, levels, request intervals and reading retention: [usage semantics](usage-semantics.md).

## Credentials

- A provider that needs a key or token reads it from the client's own configuration, environment variables or local credential files, uses it only for that provider's usage request, and never includes it in reports or stored data.
- Claude and Codex quota queries use the installed clients' existing sign-in. Codex's ID-token sign-in time is read locally to choose the client that reads the account; its access and refresh tokens are not used. Pi ChatGPT OAuth uses the existing access token for the official usage endpoint, without using its refresh token or writing credentials. No request sends a model message or consumes a usage-reset credit.
- Account identity comes only from data a provider already reads or a response it already requests: the Claude profile, Codex `account/read` and Pi’s authenticated ChatGPT usage response, Cursor's local database, the Grok login record, Antigravity's local server and, for GitHub Copilot, GitHub's `/user` response. Provider user and workspace ids are stored as hashes; the account's email or name is kept locally to label its rows.
- GitHub Copilot quota reads no credential until the user confirms Settings → Agents → GitHub Copilot → Read quota; the dialog, shown each time it is switched on, names the environment variables, the keychain item `gh:github.com` and the GitHub CLI `hosts.yml`, and macOS may ask for keychain access. Switching it off forgets the account, its rows and its quota history at once.
- OpenClaw's agent database also stores authentication profiles; only its session tables are queried.
- Custom endpoints are not assumed to share official billing accounts, and executable key resolvers are never run.
- Kimi account identity is confirmed through the official profile endpoint, separately for each deployment; only hashed credential-to-account associations are cached, and accounts are never merged from matching quota values, reset times or unverified token claims.
- DeepSeek session liveness inspection reads the executable identity and start time of the processes holding a Harness profile; it does not read the profiles' contents.

## Local storage

- Preferences use the application's UserDefaults domain; the usage ledger, the restart copy of the report and the hooks' records live in the data directory under `~/Library/Application Support`: `Agent HUD Open Desktop` for the app `scripts/build-app.sh` builds, `Agent HUD Open` when the application's `Info.plist` names none ([storage](architecture.md#storage)). Local metadata can include workspace paths and session titles, and a title can be the first line of a prompt, cut to 60 characters; raw conversation bodies and authentication secrets are never stored.
- `~/Library/Caches/app.agenthud/instance.lock` keeps a second copy of the application from starting while one runs; it holds the path of the running copy's executable and nothing else.
- Quota, balance and account-wide usage requests run between local polls, one provider at a time and at most once a minute each: more often while that client works, every 5 minutes for a client nobody is using ([cadence](usage-semantics.md#collection-cadence)); a missing or signed-out client does not prevent other sources from reporting.
- Saved readings appear immediately after a restart with their original observation times; a failed refresh keeps them and reports the failure. Unavailable quotas are never inferred from token counts.
- Readings of an account a client is no longer signed in to stay until the account has not been seen for 30 days.
- A completed credential scan retires expired, removed or rejected OpenCode Go, Kimi and GLM quota rows, including cached rows and saved display settings.
- Client hooks add one handler to a client's own settings or hooks file — Claude Code's notification hook and GitHub Copilot CLI's stop hook — leaving every other hook in it alone, and refuse to rewrite a layout they do not recognize; a rewritten file keeps its permissions. Settings → General → Client hooks off removes Agent HUD's handlers from every client and adds none back; removing never creates a file the client did not have.
- At every start, and whenever Client hooks is switched, the approval and session-origin handlers fuller builds added are taken out of Claude Code's `settings.json`, Codex's `hooks.json` and the settings of the Qoder builds, CodeBuddy, WorkBuddy, ZCode and Qwen Code, when they run this copy's executable; a handler of another program, and every other entry, stays, and so does ZCode's hooks switch. A file that holds none is not rewritten ([retired handlers](session-lifecycle.md#retired-handlers)).
- At every start, and whenever Client hooks is switched, Agent HUD's stop hooks are taken out of Antigravity, Cursor, CodeBuddy and Qwen Code, whichever copy added them; their sessions never show as running, so those hooks only fed the turn reminders this build leaves out ([completion hooks](session-lifecycle.md#completion-hooks)).
- Claude Code's notification hook keeps one record per session waiting for the user: the session id, Claude Code's notification text up to 2 KB and the time, forgotten a day later ([notification hook](session-lifecycle.md#notification-hook)).
- GitHub Copilot CLI's stop hook writes one small local record per finished turn (session and turn identity, model, workspace folder name and time) and nothing else; it sends no notifications and uploads nothing ([completion hooks](session-lifecycle.md#completion-hooks)).
- Pi's extension and OpenCode's plugin run inside those clients and write only metadata records of their turns — session and turn identity, workspace, the session's title, model, provider, times and, in iTerm2 outside tmux, the terminal session id, which this build does not read — beside the client's own data; they make no request and upload nothing ([observers](session-lifecycle.md#observers)).

## Related

[providers.md](providers.md) per-client details · [usage-semantics.md](usage-semantics.md) counting and retention · [session-lifecycle.md](session-lifecycle.md) turn evidence and hooks · [../THIRD_PARTY_NOTICES.txt](../THIRD_PARTY_NOTICES.txt) provider protocol references and licenses
