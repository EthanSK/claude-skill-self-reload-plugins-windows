# self-reload-plugins (Windows): find Claude Code's terminal window via
# process-tree walk and dispatch `/reload-plugins` into it via SendKeys.
#
# Strategy:
#   1. Walk up the parent-process chain from $PID until we find an ancestor
#      whose Win32 MainWindowHandle != 0 (i.e. a console host with a real
#      visible window).
#   2. SetForegroundWindow on that hwnd, then SendKeys "/reload-plugins{ENTER}".
#   3. If the walk yields no windowed ancestor, fall back to scanning processes
#      whose MainWindowTitle CONTAINS "claude" (case-insensitive). NEVER fall
#      through to "PowerShell" / "Windows Terminal" / etc. — that's how the
#      previous version dispatched into the wrong window.
#   4. If still nothing, exit non-zero.
#
# Logging: appends NDJSON records to ~/.claude/logs/skills.log per the
# convention in CLAUDE.md.

[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms

# --- Logging helper ---------------------------------------------------------
$LogPath = Join-Path $env:USERPROFILE ".claude\logs\skills.log"
$LogDir  = Split-Path -Parent $LogPath
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-SkillLog {
    param(
        [Parameter(Mandatory)] [string]$Event,
        [string]$Level = 'info',
        [hashtable]$Context = @{}
    )
    $entry = [ordered]@{
        ts        = (Get-Date).ToString("o")
        host      = $env:COMPUTERNAME
        component = "skill"
        skill     = "self-reload-plugins"
        event     = $Event
        level     = $Level
        context   = $Context
    }
    try {
        $json = ($entry | ConvertTo-Json -Compress -Depth 6)
        Add-Content -Path $LogPath -Value $json -ErrorAction SilentlyContinue
    } catch {}
}

# --- Win32 SetForegroundWindow ---------------------------------------------
$signature = @'
using System;
using System.Runtime.InteropServices;

public static class Win32Fg {
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
}
'@
if (-not ([System.Management.Automation.PSTypeName]'Win32Fg').Type) {
    Add-Type -TypeDefinition $signature -ErrorAction SilentlyContinue
}

Write-SkillLog -Event "skill.start" -Context @{ pid = $PID; dryRun = [bool]$DryRun }

# --- Walk the ancestor chain from $PID --------------------------------------
# Take a single snapshot of all processes up front. Walking lazily with
# Get-CimInstance per ancestor races against short-lived shells (each Bash-tool
# call spawns a bash subprocess that may exit between the time we record it
# and the time we query its parent), so we lose the chain at the first dead
# link. With a snapshot we have a stable PID→ParentPid map.
$cimAll = @{}
try {
    Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object {
        $cimAll[[int]$_.ProcessId] = [int]$_.ParentProcessId
    }
} catch {}

$shellHostNames = @(
    'WindowsTerminal', 'wt',
    'pwsh', 'powershell',
    'bash', 'mintty',
    'conhost', 'cmd',
    'OpenConsole'
)

$chain    = @()
$cursor   = $PID
$maxDepth = 25
$found    = $null
$visited  = @{}

for ($i = 0; $i -lt $maxDepth; $i++) {
    if ($cursor -le 0) { break }
    if ($visited.ContainsKey($cursor)) { break }  # cycle guard
    $visited[$cursor] = $true

    $proc = $null
    try { $proc = Get-Process -Id $cursor -ErrorAction Stop } catch {}

    if ($proc) {
        $entry = @{
            pid    = $proc.Id
            name   = $proc.ProcessName
            title  = $proc.MainWindowTitle
            hwnd   = [int64]$proc.MainWindowHandle
            isHost = ($shellHostNames -contains $proc.ProcessName)
        }
        $chain += ,$entry

        if ($proc.MainWindowHandle -ne [IntPtr]::Zero -and $proc.MainWindowHandle -ne 0) {
            $found = $entry
            break
        }
    } else {
        # Process already exited; record the PID so the chain stays continuous.
        $chain += ,@{ pid = $cursor; name = '<exited>'; title = ''; hwnd = 0; isHost = $false }
    }

    if ($cimAll.ContainsKey($cursor)) {
        $cursor = $cimAll[$cursor]
    } else {
        # PID not in the snapshot — try a one-off CIM lookup as last resort.
        try {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId = $cursor" -ErrorAction Stop
            if ($p) { $cursor = [int]$p.ParentProcessId } else { $cursor = 0 }
        } catch { $cursor = 0 }
    }
}

# --- Fallback A: locate claude.exe and use its parent's window --------------
# When the upward walk dies (Bash-tool spawner already exited), we can still
# find Claude by name. Each `claude` process's parent is the terminal hosting
# the session — that's the window we want.
if (-not $found) {
    Write-SkillLog -Event "skill.fallback" -Context @{ reason = "no windowed ancestor"; chainDepth = $chain.Count; stage = "claude-parent" }
    $claudeProcs = Get-Process -Name 'claude' -ErrorAction SilentlyContinue
    foreach ($cp in $claudeProcs) {
        $parentPid = 0
        if ($cimAll.ContainsKey($cp.Id)) {
            $parentPid = $cimAll[$cp.Id]
        } else {
            try {
                $cimP = Get-CimInstance Win32_Process -Filter "ProcessId = $($cp.Id)" -ErrorAction Stop
                if ($cimP) { $parentPid = [int]$cimP.ParentProcessId }
            } catch {}
        }
        if ($parentPid -le 0) { continue }
        try {
            $parentProc = Get-Process -Id $parentPid -ErrorAction Stop
            if ($parentProc.MainWindowHandle -ne [IntPtr]::Zero -and $parentProc.MainWindowHandle -ne 0) {
                $found = @{
                    pid    = $parentProc.Id
                    name   = $parentProc.ProcessName
                    title  = $parentProc.MainWindowTitle
                    hwnd   = [int64]$parentProc.MainWindowHandle
                    isHost = $true
                    via    = "claude-parent"
                }
                break
            }
        } catch {}
    }
}

# --- Fallback B: scan windowed processes whose title contains "claude" -----
# Last resort. Never falls through to "PowerShell" / "Windows Terminal" /
# anything else — only matches windows whose title literally contains "claude".
if (-not $found) {
    Write-SkillLog -Event "skill.fallback" -Context @{ reason = "claude-parent miss"; stage = "title-match" }
    $candidates = Get-Process | Where-Object {
        $_.MainWindowHandle -ne [IntPtr]::Zero -and
        $_.MainWindowTitle -and
        ($_.MainWindowTitle -imatch 'claude')
    }
    if ($candidates) {
        $best = $candidates | Select-Object -First 1
        $found = @{
            pid    = $best.Id
            name   = $best.ProcessName
            title  = $best.MainWindowTitle
            hwnd   = [int64]$best.MainWindowHandle
            isHost = $true
            via    = "title-fallback"
        }
    }
}

if (-not $found) {
    $chainSummary = ($chain | ForEach-Object { "$($_.pid):$($_.name)" }) -join " -> "
    Write-SkillLog -Event "skill.error" -Level "error" -Context @{ err = "no windowed ancestor and no claude-titled window"; chain = $chainSummary }
    Write-Error "Could not locate Claude session window (walked $($chain.Count) ancestors, no fallback match for 'claude' in title)."
    exit 2
}

# --- Report (and stop here if dry-run) --------------------------------------
$hexHwnd = [Convert]::ToString([int64]$found.hwnd, 16)
$msg = "Would dispatch to PID=$($found.pid), hwnd=0x$hexHwnd, title='$($found.title)', name='$($found.name)'"
Write-Output $msg

if ($DryRun) {
    Write-SkillLog -Event "skill.dryrun" -Context @{ pid = $found.pid; hwnd = $found.hwnd; title = "$($found.title)"; name = $found.name }
    exit 0
}

# --- Bring window to foreground and SendKeys --------------------------------
$hwndPtr = [IntPtr]::new([int64]$found.hwnd)
[void][Win32Fg]::ShowWindow($hwndPtr, 9)  # SW_RESTORE
[void][Win32Fg]::SetForegroundWindow($hwndPtr)

Start-Sleep -Milliseconds 300

# `/reload-plugins` contains no SendKeys metacharacters — safe verbatim.
[System.Windows.Forms.SendKeys]::SendWait('/reload-plugins{ENTER}')

Write-SkillLog -Event "skill.end" -Context @{ pid = $found.pid; hwnd = $found.hwnd; title = "$($found.title)"; name = $found.name }
Write-Output "Dispatched /reload-plugins to PID=$($found.pid) ($($found.name))."
exit 0
