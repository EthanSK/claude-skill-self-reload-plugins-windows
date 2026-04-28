#!/usr/bin/env bash
# self-reload-plugins (Windows): dispatch `/reload-plugins` into the running
# Claude Code terminal via PowerShell SendKeys. Mirrors the macOS version's
# intent but uses WScript.Shell.AppActivate instead of AppleScript.

set -uo pipefail

LOG_SKILL="self-reload-plugins"
# shellcheck disable=SC1091
[ -f "$HOME/.claude/scripts/skill-log.sh" ] && . "$HOME/.claude/scripts/skill-log.sh"
_log() { command -v skill_log >/dev/null 2>&1 && skill_log "$@" || true; }
_log info "skill.start" "{}"

PS1_PATH="$HOME/.claude/skills/self-reload-plugins/scripts/reload.ps1"
if [ ! -f "$PS1_PATH" ]; then
  _log error "skill.error" "{\"err\":\"reload.ps1 not found\",\"path\":\"$PS1_PATH\"}"
  echo "Error: reload.ps1 not found at $PS1_PATH" >&2
  exit 1
fi

# Convert to Windows path so powershell.exe finds it whether invoked from
# Git Bash or cmd.
WIN_PS1=$(cygpath -w "$PS1_PATH" 2>/dev/null || echo "$PS1_PATH")

# Forward --dry-run / -DryRun to the PowerShell script.
PS_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run|-DryRun|--dryrun) PS_ARGS+=("-DryRun") ;;
  esac
done

OUT=$(powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_PS1" "${PS_ARGS[@]}" 2>&1)
RC=$?

echo "$OUT"
if [ "$RC" -eq 0 ]; then
  _log info "skill.end" "{\"ok\":true}"
else
  _log error "skill.error" "{\"rc\":$RC,\"out\":\"${OUT//\"/\\\"}\"}"
fi
exit $RC
