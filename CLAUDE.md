# Notch Agent

Native Swift/SwiftUI clone of Drop Notch (dropnotch.space): coding agents (Claude Code, Codex, herdr panes, other CLIs) in the MacBook notch, or a tab at the top of the menu bar on displays without one. See README.md for features.

## Build, run, install

```bash
swift build                          # must build with zero errors and warnings
.build/debug/NotchAgent              # dev run (kill the installed one first: pkill -x NotchAgent)
./scripts/build-app.sh install       # release → /Applications/NotchAgent.app, restarts it
```

Swift package, no Xcode project. `npx tsc`/`eslint` don't apply here — `swift build` is the check.

## Where things are

| File | What |
|---|---|
| `App.swift` | App delegate, `NotchController` (window, modes closed/peek/drop/open, pointer hit-testing, ⌥Space hotkey), `EventLog`, debug JSON, login item |
| `NotchView.swift` | All notch UI: tab, pages (Threads, Thread, Usage, Stats, Music), dock, drop-down card, settings menu |
| `Store.swift` | Sessions model: hook events, herdr + process merging, approvals, replies, drop events |
| `HookBridge.swift` | Loopback HTTP server (port 47823), hook payloads, `HookInstaller` (Claude + Codex), `TerminalBridge` (replies) |
| `Herdr.swift` | herdr CLI wrapper + monitor, terminal screen/title reading |
| `Agents.swift` | Process scanner for agent CLIs outside herdr/hooks |
| `AgentLog.swift` | Reads last prompt/reply from Claude transcripts and Codex session logs |
| `Ask.swift` / `Screen.swift` | Ask page (launch agents, model catalogs, Fable access) / screenshots + attachments |
| `Usage.swift` / `Limits.swift` | Token/cost usage (Claude + Codex logs) / plan limits, plan + Fable billing |
| `Music.swift` / `SystemStats.swift` / `Motion.swift` | Player + lyrics / stats / animation, glyphs, glass, FrameProbe |

## Testing

- Debug builds answer `curl 127.0.0.1:47823/debug` (mode, page, sessions, probed frames, drop, idle).
- Fake agent events: POST hook JSON to `127.0.0.1:47823/hook` with headers `X-Notch-Agent: 1` (and `X-Agent: codex` for Codex).
- Debug-only switches: `/tmp/notch-agent-force-away` (pretend user is away), `/tmp/notch-agent-no-notch` (lay out as no-notch).
- What the installed app did: `~/Library/Logs/NotchAgent.log`.
- Verify UI changes on screen with human-like pointer movement + screenshots, not just a build. The user's Mac is often docked lid-closed (main display LG 2560×1440, notch-less). Tests move the user's real pointer — say so.

## Gotchas (learned the hard way)

- Hit-testing must use `FrameProbe` (AppKit views asked for their frame on demand). SwiftUI preference keys and `onGeometryChange` went stale after animated layout changes and made the notch close under the pointer.
- Replies to agent TUIs go in as a bracketed paste (`ESC[200~…ESC[201~`), otherwise Claude Code/Codex swallow the Return.
- Codex hooks need the user's one-time trust inside Codex (`trusted_hash` in `~/.codex/config.toml`). Never write that hash ourselves.
- Codex's Stop hook can arrive ~2 s after herdr reports the pane done.
- Fable billing comes from Claude Code's cached server flags in `~/.claude.json` (`tengu_saffron_lattice`, `tengu_saffron_credits_only_tiers`); don't hard-code "needs credits".
- Plan-limit endpoint rate-limits: refresh ≤ every 5 min, keep last values on error.
