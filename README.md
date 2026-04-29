# self-reload-plugins (Windows)

A Claude Code skill that lets Claude self-recover from MCP/plugin disconnects by dispatching `/reload-plugins` into the running Claude Code terminal session — without the user having to type it.

This is the **Windows port** of the skill. The **macOS standalone version** lives at [EthanSK/claude-skill-self-reload-plugins-mac](https://github.com/EthanSK/claude-skill-self-reload-plugins-mac) and uses AppleScript to drive iTerm2 / Terminal.app / Ghostty / WezTerm / kitty / Alacritty. The macOS version is also tracked in-monorepo at [EthanSK/dot-claude](https://github.com/EthanSK/dot-claude) under `skills/self-reload-plugins/`.

## How it works

`scripts/reload.sh` is a thin Git Bash wrapper that invokes `scripts/reload.ps1` via `powershell.exe`. The PowerShell script locates the Claude session window using a layered strategy:

1. **Process-tree walk (primary).** Snapshots all running processes once, then walks the parent chain from `$PID` upward looking for an ancestor whose `MainWindowHandle != 0`. The snapshot avoids races against short-lived shells (each Claude Bash-tool call spawns a bash subprocess that may exit between sampling and lookup).
2. **`claude.exe` parent fallback.** If the upward walk dies — typically because the Bash-tool spawner already exited — find each `claude.exe` process and check its parent. The parent of `claude.exe` is the terminal hosting the session.
3. **Title-match fallback.** Last resort: scan all windowed processes whose `MainWindowTitle` literally contains "claude" (case-insensitive). This NEVER falls through to "PowerShell" / "Windows Terminal" / etc. — only windows whose title contains "claude".

Once a window is identified, the script calls Win32 `SetForegroundWindow` on the hwnd and uses `[System.Windows.Forms.SendKeys]::SendWait("/reload-plugins{ENTER}")` to dispatch the slash command.

If no window can be located, the script exits non-zero with a clear stderr message — it never blind-keystrokes into the foreground app.

## Install

Clone this repo into your Claude Code skills directory:

```bash
git clone https://github.com/EthanSK/claude-skill-self-reload-plugins-windows.git \
  ~/.claude/skills/self-reload-plugins
```

Or, on Windows from PowerShell:

```powershell
git clone https://github.com/EthanSK/claude-skill-self-reload-plugins-windows.git `
  $env:USERPROFILE\.claude\skills\self-reload-plugins
```

Claude Code should pick up the skill on next session start (or run `/reload-plugins` once manually).

## Usage

Trigger phrases (auto-matched by Claude):

- "reload my plugins"
- "reload plugins"
- "mcp server dropped"
- "chrome-devtools disconnected"
- "refresh my tools"
- "can you reload plugins yourself"
- "self-reload"

Claude can also auto-invoke this skill when it detects an expected MCP tool/plugin has stopped responding mid-session.

## Dry-run / debugging

```bash
bash ~/.claude/skills/self-reload-plugins/scripts/reload.sh --dry-run
```

Prints the resolved `PID`, `hwnd`, window title, and process name without sending any keystrokes. Useful for verifying window detection on a new machine.

NDJSON skill events (start, fallback, end, error) append to `~/.claude/logs/skills.log` per the [unified skill-log convention](https://github.com/EthanSK/dot-claude-dell/blob/main/CLAUDE.md#debugging-skills--unified-log-first).

## Mac vs Windows

| | Mac (`EthanSK/claude-skill-self-reload-plugins-mac`) | Windows (this repo) |
|-|-|-|
| Window detection | AppleScript via `osascript`, with tty-match for iTerm2/WezTerm/kitty | PowerShell process-tree walk + `claude.exe` parent fallback |
| Send keystroke | AppleScript `tell app "iTerm" to write text` (etc.) | Win32 `SetForegroundWindow` + `[System.Windows.Forms.SendKeys]::SendWait` |
| Terminal coverage | iTerm2, Terminal.app, Ghostty, WezTerm, kitty, Alacritty | Windows Terminal, PowerShell host, mintty (Git Bash), ConHost, OpenConsole — by hwnd, not title |

## License

MIT — same as `EthanSK/dot-claude` and `EthanSK/dot-claude-dell`.
