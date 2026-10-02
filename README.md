# Notch Agent

Your coding agents, in the MacBook notch. Watch Claude Code (and herdr's
Codex panes) work, approve tool calls, reply, start new agents, and keep an
eye on usage, plan limits, your Mac and your music, without hunting for the
right terminal.

Native Swift/SwiftUI, no Electron, nothing leaves your Mac except the two
lookups noted under [Network](#network).

## Install

```bash
./scripts/build-app.sh install
```

Builds a release `NotchAgent.app`, signs it with your Apple Development
certificate if you have one (so macOS remembers its permissions across
rebuilds), copies it to `/Applications` and starts it. It opens at login from
then on; turn that off in the notch's ⚙ menu.

Then open the notch, click ⚙ → **Install Claude Code hooks**. That adds hooks
to `~/.claude/settings.json` (a backup is saved next to it). New Claude Code
sessions show up right away; running ones after their next prompt.

Requires macOS 14+. On Macs without a notch it sits as a tab at the top
centre of the menu bar.

## Using it

| | |
|---|---|
| Hover the notch | Peeks |
| Click, or **⌥ Space** | Opens (⌥ Space lands on Ask, ready to type) |
| **Esc** | Closes |

- **Closed**, the notch says what's happening: `✢ project … ⟳ Bash`, Claude's
  live thinking verb (`Combobulating…`), **Needs you**, **✓ Done**, or
  `3 running`. With nothing running and music playing: cover, waves, lyric.
- **Ask**: start Claude or Codex with a prompt, in a folder, with a model and
  permission mode, in a new herdr tab or a Terminal window.
- **Threads**: every session with its prompt, model, live timer and tool calls
  ("188 lines", "+14 −3"). Approve or deny permission requests, reply into
  the agent's terminal, or jump to it (↗).
- **Usage**: Claude plan limits (5-hour session and weekly), plus token use
  and API-equivalent cost by day, model and project from Claude Code's logs.
- **Stats**: CPU, GPU, memory, battery, disk, thermal state.
- **Music**: Apple Music or Spotify, with controls and karaoke lyrics.

## How it works

- **Claude Code hooks** (`curl` to `127.0.0.1:47823`) report each prompt, tool
  call, permission request and turn end. Permission requests wait for your
  click; everything else is answered immediately, so agents never stall. If
  the app isn't running, the hooks do nothing.
- **herdr** (if installed): its agent list adds panes the hooks don't cover
  (Codex, older sessions), and replies go through `herdr agent prompt`, which
  works in any terminal herdr runs in, Metalterm included.
- **Terminal / iTerm2**: replies are typed into the right tab by AppleScript.
  Other terminals (Metalterm without herdr, Ghostty, VS Code…) can't be typed
  into from outside, so the reply is copied for you to paste.
- **Staying accurate**: Claude Code titles its tab `◐ …` while working and
  `✳ …` when waiting. If a hook goes missing, the notch trusts the title (or
  herdr's status) after two readings that disagree.

## Permissions

macOS asks once for each:

- **Automation → Terminal / iTerm2**: to type replies and read tab titles.
- **Automation → Music / Spotify**: now playing and controls.
- **Keychain** (maybe): plan limits use the sign-in Claude Code already keeps
  there; it's only sent to `api.anthropic.com`.

## Network

- `api.anthropic.com/api/oauth/usage`: plan limits, with your Claude Code sign-in.
- `lrclib.net`: lyrics, sending only the song's title, artist, album and length.

## Uninstall

⚙ → **Remove Claude Code hooks**, quit, then delete `/Applications/NotchAgent.app`
(System Settings › General › Login Items drops it automatically).

## Development

```bash
swift build && .build/debug/NotchAgent   # run from the terminal
./scripts/build-app.sh                   # just build build/NotchAgent.app
```

Debug builds also answer `GET http://127.0.0.1:47823/debug` with a JSON
snapshot of sessions and layout, for scripted checks.
