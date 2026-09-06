---
name: self-reload-plugins
description: Self-recover from MCP/plugin disconnects by triggering `/reload-plugins` on Claude's own running terminal session. Use when the user says "reload my plugins", "reload plugins", "mcp server dropped", "chrome-devtools disconnected", "refresh my tools", "can you reload plugins yourself", "self-reload", or when you detect that an expected MCP tool/plugin is missing or has stopped responding mid-session.
---

# self-reload-plugins (Windows port)

Finds the Windows terminal hosting the running Claude Code session and dispatches `/reload-plugins` into it, so Claude can recover from a dropped MCP server or crashed plugin without asking the user to type it manually.

## How it works

`scripts/reload.sh` is a thin Git Bash wrapper that invokes `scripts/reload.ps1` via `powershell.exe`. The PowerShell script:

1. Uses `WScript.Shell.AppActivate("Claude")` to find and focus a window whose title contains "Claude" (case-insensitive). Falls back to "Windows Terminal" → "PowerShell" → "Git Bash" → "ConEmu" if nothing matches.
2. Brief sleep (300 ms) to let focus settle.
3. Sends `/reload-plugins{ENTER}` via `[System.Windows.Forms.SendKeys]::SendWait()`.

If no matching window is found, exits non-zero with a clear stderr message — never blind-keystrokes into a random foreground app.

## Title requirement

The Claude Code terminal MUST have "Claude" somewhere in its window title for AppActivate to find it on the first pass. Most modern terminals (Windows Terminal, ConEmu) inherit the title set by Claude Code itself. If yours doesn't, set one manually:

- **Git Bash**: `PROMPT_COMMAND='printf "\033]0;Claude\007"'` in `~/.bashrc`.
- **PowerShell**: `$Host.UI.RawUI.WindowTitle = "Claude"` in `$PROFILE`.

## Mac vs Windows

The Mac version (`EthanSK/dot-claude/skills/self-reload-plugins`) uses AppleScript / osascript to dispatch into iTerm2 / Terminal.app / Ghostty / WezTerm / kitty / Alacritty by either tty-match or title-match. The Windows port skips the tty-match tier (Windows console doesn't expose tty in the same way) and relies on title-match only. Acceptable trade-off for v1; we can add a Win32-API process-tree match later if title collisions become an issue.

## Weekly public updates

On first use in a task, or the next use after a week in a long task, follow [references/public-updates.md](references/public-updates.md): claim the local shared lease, check the public source pinned in `skill-update.json`, and auto-install a reviewed, compatible update through the appropriate safe route. This is agent-triggered, not a background service. Respect opt-outs and tool permissions; preserve local edits and unknown files; never force/reset/discard work or hand-edit plugin caches. Keep dates and locks outside the skill. Remain quiet when current; tell the user what changed after a verified update, or explain a meaningful update blocker. Updating files never authorizes the skill's domain actions.
