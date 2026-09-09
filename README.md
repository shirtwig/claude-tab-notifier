# Claude Tab Notifier

Marks the Windows Terminal tab a [Claude Code](https://claude.com/claude-code) session is running in with a `✨` prefix when Claude finishes responding or needs your input, and plays a sound. Submitting a new prompt clears the marker.

```
before:  PowerShell
after:   ✨ PowerShell
```

## Supported environment

- **Windows** with **Windows Terminal** (the marker relies on `WT_SESSION`, an environment variable Windows Terminal injects into every pane — it will not work in the legacy `conhost.exe` window, VS Code's integrated terminal, or other terminal emulators).
- **PowerShell** (Windows PowerShell 5.1, the version that ships with Windows) — fully supported, including automatic watcher start-up.
- **CMD.exe** — the watcher itself (`watcher-cmd.ps1`) is implemented and tested, but the installer does not yet wire up automatic start-up for CMD tabs. See [CMD support](#cmd-support) below.
- `.NET SDK` is required at install time to build the hook (`dotnet publish`).

## What it actually does

```
Claude Code hook (Notification / Stop / UserPromptSubmit)
    -> reads its own WT_SESSION from the environment
    -> writes %LOCALAPPDATA%\ClaudeTabNotifier\state\<WT_SESSION>.json
           { "status": "needsAttention" | "clear" }

Watcher (running inside your Windows Terminal tab)
    -> polls its own WT_SESSION's state file every 500ms
    -> on "needsAttention": marks the tab title with ✨ and plays a sound
    -> on "clear": restores the original tab title
```

`WT_SESSION` is the GUID Windows Terminal assigns to each pane. It's what lets the hook (which only knows its own environment) and the watcher (also only aware of its own environment) agree on which tab a given Claude Code session belongs to, without either one needing to enumerate or discover the other.

## Installation

Requires the .NET SDK (for `dotnet publish`) and PowerShell.

1. Download the Release ZIP from GitHub and extract it.
2. Open PowerShell inside the extracted folder.
3. Run:
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\install.ps1
   ```
   Running `.\install.ps1` on its own — or double-clicking the file, or "Run with PowerShell" from the right-click menu — is **not** the supported install path: PowerShell does not run scripts from the current directory without either an explicit `.\` prefix or an execution-policy override, and depending on your system's default execution policy either of those alone may still be refused. The command above is the one actually needed.
4. Follow the installer's prompts to choose a notification sound and an attention emoji (press Enter at either prompt to keep the current/default choice).
5. Open a new Windows Terminal tab and start `claude` as usual — the watcher starts automatically via `$PROFILE`.

This will:
1. Build `ClaudeAttention.exe` (the hook) and deploy it to `~/.claude/tools/ClaudeAttention.exe`.
2. Deploy the watcher, sound files, and `config.json` to `%LOCALAPPDATA%\ClaudeTabNotifierPOC\`.
3. Ask you to choose a notification sound and an attention emoji, saving the choice to `config.json` (re-running the installer later shows your current choice and keeps it on Enter — see [Configuration](#configuration) below).
4. Add `Notification`, `Stop`, and `UserPromptSubmit` hooks to `~/.claude/settings.json`, and set `env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` (see [why this is needed](#why-claude_code_disable_terminal_title-is-required) below). Any other content already in `settings.json` — other hooks, other env vars, anything else — is left untouched.
5. Add a small auto-start block to your PowerShell `$PROFILE`, so the watcher starts automatically in every new PowerShell tab. Anything else already in your profile is preserved.

It's safe to run more than once: every step checks whether it already applied before changing anything, so re-running doesn't duplicate hooks or profile blocks. It also backs up `settings.json` and `$PROFILE` (as `<file>.backup-<timestamp>`) immediately before actually modifying either one.

If you've already installed and just closed/reopened PowerShell tabs, that alone is enough for the watcher to start — no need to re-run the installer.

## Uninstalling

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Removes exactly what the installer added:
- The three hook entries from `settings.json` (nothing else in that file is touched).
- `env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE` — **restored to whatever value it had before install** if it already existed, or removed entirely if the installer was the one who added it from nothing. This is tracked in an install manifest so uninstall never guesses.
- The auto-start block from `$PROFILE` (nothing else in that file is touched).
- The deployed hook exe, watcher script, sound files, and config.
- The install manifest itself, and the deploy directory if it ends up empty.

Runtime state under `%LOCALAPPDATA%\ClaudeTabNotifier\state\` (heartbeats, per-session logs, the cleanup log) is left alone — it's debugging data, not an installed file, and cleans itself up over time via each watcher's own orphan-detection sweep.

## Configuration

Edit `%LOCALAPPDATA%\ClaudeTabNotifierPOC\config.json`:

```json
{
  "soundEnabled": true,
  "selectedSound": "classic",
  "customSoundFile": "",
  "selectedEmoji": "sparkle"
}
```

- `soundEnabled` — set to `false` to disable sound entirely (the title still marks/clears normally).
- `selectedSound` — one of the built-in names below, or `"custom"` to use `customSoundFile`.
- `customSoundFile` — a path to your own `.wav` file, used when `selectedSound` is `"custom"`. Relative paths are resolved against the deploy directory; absolute paths are used as-is.
- `selectedEmoji` — which emoji marks a tab that needs attention; one of the 12 names below.

To change any of these by hand, edit only the field(s) you want to change and leave the rest of the file exactly as it is — each field is independent, so editing `selectedEmoji` never touches `selectedSound`/`soundEnabled`/`customSoundFile` or vice versa (this is also how the installer's own sound/emoji prompts behave: each one only ever writes its own field). An unrecognized value in either `selectedSound` or `selectedEmoji` is treated the same as if it were missing — it silently falls back to the default (`classic` / `sparkle`) rather than erroring.

Config is re-read each time a watcher starts (i.e., each time you open a new tab) — it's not hot-reloaded into already-running watchers. A missing or malformed `config.json` falls back to the defaults shown above rather than failing.

Run `%LOCALAPPDATA%\ClaudeTabNotifierPOC\test-sound.ps1` to preview your current sound, or `test-sound.ps1 -Sound <name>` to preview any built-in sound regardless of your current config.

### Built-in sounds

| Name | Description |
|---|---|
| `classic` | Two-tone sine sweep (the default) |
| `chime` | Soft sine with a quiet overtone |
| `soft` | Single low, quiet tone |
| `alert` | Two sharp pulses |
| `retro` | Stepped square wave |
| `magic` | Ascending 4-note arpeggio |
| `digital` | Two short high-pitched blips |
| `double` | Two identical beeps |
| `scifi` | Continuous frequency sweep |
| `success` | Ascending 3-note major arpeggio |

All ten are procedurally synthesized for this project (see `sounds/SOUNDS.md`) — no third-party samples.

### Built-in emoji, and the pulse

| Name | Emoji |
|---|---|
| `sparkle` | ✨ (the default) |
| `star` | ⭐ |
| `bell` | 🔔 |
| `bolt` | ⚡ |
| `fire` | 🔥 |
| `target` | 🎯 |
| `check` | ✅ |
| `reddot` | 🔴 |
| `eyes` | 👀 |
| `chat` | 💬 |
| `heart` | ❤️ |
| `music` | 🎵 |

The chosen emoji appears as a prefix in the tab title while the session needs attention, and *pulses* there: it's the same emoji throughout (never swapped for a different one) repeated a cycling number of times — 1 copy, then 2, then 3, then back down to 2, and so on — which is the closest approximation of a "grow/shrink" animation achievable inside a plain console title string (Windows Terminal titles are text, with no per-character font-size control). Submitting a prompt stops the pulse and restores the original title exactly.

## The notification lifecycle

1. Claude finishes responding, or is waiting on you for input (`Stop` / `Notification` hooks fire) → the tab title gets a `✨` prefix and the configured sound plays once.
2. You submit your next prompt (`UserPromptSubmit` hook fires) → the `✨` is removed and the title returns to normal.
3. If Claude finishes again before you submit anything, the tab is already marked and nothing re-fires (no repeated sounds or redundant title writes for an unchanged state).

**Important limitation:** the marker clears on *submitting a prompt*, not on *switching to the tab*. Windows Terminal has no API that lets an external process detect which tab currently has focus ([microsoft/terminal#19783](https://github.com/microsoft/terminal/issues/19783), [#19818](https://github.com/microsoft/terminal/issues/19818)), so "you looked at it" can't be distinguished from "you haven't looked at it yet" — only "you've now sent Claude something new" is observable. In practice this means the `✨` can stay on a tab you've already glanced at until you actually type your next message in it.

## Why `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` is required

Claude Code manages the console title itself — a spinner while it's working, a summary title when it finishes — and this races with the watcher's own title writes around the same `Stop` event; whichever write lands last wins, non-deterministically. Setting `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` (which the installer does automatically, in `settings.json`'s `env` block) stops Claude Code from touching the title at all, leaving the watcher as the sole owner of it. This variable isn't part of Claude Code's official documentation; it surfaced through a public statement from an Anthropic engineer and has had at least one reported Windows-specific regression ([anthropics/claude-code#16572](https://github.com/anthropics/claude-code/issues/16572)). The hook logs a warning to `~/.claude/tools/claudeattention.log` on every invocation if it doesn't see this variable set to `1` in its own environment, so a regression would be visible rather than silently reintroducing the race.

## CMD support

`watcher-cmd.ps1` implements the same marking/dedup/sound/log-rotation/orphan-cleanup behavior as the PowerShell watcher, adapted for CMD.exe (it runs as a genuinely separate process launched via `start /B`, rather than a background thread inside the shell — CMD has no equivalent of PowerShell's in-process runspaces). It is exercised by the full automated test suite alongside the PowerShell watcher.

**However, `install.ps1` does not currently deploy it or wire up any CMD auto-start mechanism** — only the PowerShell `$PROFILE` path is automated. To use it manually in a CMD tab today: copy `watcher-cmd.ps1` and `watcher-cmd.cmd` into `%LOCALAPPDATA%\ClaudeTabNotifierPOC\`, then run `watcher-cmd.cmd` at the start of a CMD session before running `claude`.

## Development / testing

Requires [Pester](https://pester.dev/) (the version bundled with Windows PowerShell 5.1 — the test suite uses its older `Should Be` syntax, not the modern `Should -Be`).

```powershell
.\tests\RunAll.ps1
```

Runs the full suite: `HookExe.Tests.ps1`, `WatcherCore.Tests.ps1`, `OrphanCleanup.Tests.ps1`, `ConcurrentSessions.Tests.ps1`, `LogRotation.Tests.ps1`, `InstallUninstall.Tests.ps1`. All of it runs against isolated sandbox paths (fake `%LOCALAPPDATA%`, fake `~/.claude/settings.json`, fake `$PROFILE`) — none of it touches your real environment. Every test cleans up its own processes and files, including on failure.

**Covered by automated tests:** hook payload parsing and state writing, WT_SESSION-to-state mapping, the full mark → clear → mark cycle, deduplication (no repeated sound/title-write for an unchanged status), all 10 built-in sounds plus custom/missing/invalid sound files, missing/malformed `config.json`, missing/malformed state files, cross-session dead-process cleanup with PID-reuse-safe identity verification, CMD orphan self-termination, the cleanup log, heartbeat file schema, log rotation at the 1MB cap, `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` detection, multiple concurrent sessions with no cross-contamination, and installer/uninstaller behavior (fresh install, idempotent re-install, settings/profile backup and preservation of unrelated content, manifest-driven env-key restore).

**Not covered by automated tests** (inherently require a real environment): the visible `✨` actually appearing in a real Windows Terminal tab, the sound actually being audible, `WT_SESSION` actually being supplied by Windows Terminal itself, a real `claude` CLI session actually invoking the hook, and `$PROFILE` auto-start firing in a genuinely fresh interactive shell. These have been manually verified in a real Windows Terminal environment (fresh-tab auto-start, real hook/`WT_SESSION` wiring, the full mark → sound → clear → mark cycle, and two concurrent tabs with no cross-contamination) — they remain outside the automated suite by nature, not because they're unverified.

## Troubleshooting

- **No marker ever appears:** confirm you're in Windows Terminal, not `conhost.exe` or another terminal — check that `$env:WT_SESSION` is set. Confirm the watcher is running (a new PowerShell tab should print a short startup banner after install).
- **Marker sometimes gets overwritten right after it appears:** check `~/.claude/tools/claudeattention.log` for a `WARNING: CLAUDE_CODE_DISABLE_TERMINAL_TITLE=...` line — if present, the env var isn't taking effect (possibly a Claude Code regression; see the GitHub issue linked above).
- **No sound:** confirm `soundEnabled` is `true` in `config.json`, and that the selected sound file exists. Run `test-sound.ps1` to check independently of the watcher. Check the per-session watcher log at `%LOCALAPPDATA%\ClaudeTabNotifier\state\_watcherlog_<WT_SESSION>.txt` for `sound SKIPPED`/`sound FAILED` lines.
- **General diagnosis:** every watcher session writes its own log to `%LOCALAPPDATA%\ClaudeTabNotifier\state\_watcherlog_<WT_SESSION>.txt`, and the cross-session cleanup sweep logs to `_cleanup.log` in the same folder. The hook itself logs every invocation to `~/.claude/tools/claudeattention.log`.

## License

This project is distributed under the **MIT License** — see the [LICENSE](LICENSE) file at the repository root for the full text.

### Disclaimer

The software is provided "AS IS", without warranties of any kind, express or implied. There is no guarantee that it will be error-free or suitable for every environment. Use of the software is at your own risk. Please see the included MIT License for the applicable license terms.
