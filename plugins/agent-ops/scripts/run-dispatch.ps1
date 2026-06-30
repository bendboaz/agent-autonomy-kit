# run-dispatch.ps1 - scheduled headless dispatcher for a consuming repo's agent-ops loop.
# Cost-aware: the ready-issue SELECTION is deterministic (pure gh, no LLM); only launches
# `claude -p` when there is a dispatchable issue AND open-PR capacity. Exponential backoff on
# usage limits via <stateDir>/dispatch.backoff. Registered per-repo by install-tasks.ps1.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File run-dispatch.ps1 -RepoRoot <repo root>
param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference = 'Continue'
Set-Location $RepoRoot
$env:AGENT_LOOP     = '1'        # mark as a dispatched loop -> deny-hook blocks .agent-ops edits
$env:AGENT_OPS_REPO = $RepoRoot  # tell the config loader which repo this is

. "$PSScriptRoot\common.ps1"     # plugin engine; loads $RepoRoot/.agent-ops/config.json

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
function Log($m) { Write-Host ("[{0}] dispatch: {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

# --- backoff gate ---
if (Test-LoopBackoff 'dispatch') {
    $b = Get-LoopBackoffInfo 'dispatch'
    Log "in backoff until $($b.until) (level $($b.level)); skipping."
    exit 0
}

# --- mint App token ---
if (-not (Initialize-AgentAuth)) { Log "token mint failed; skipping."; exit 1 }

# --- log any active dispatch lock files (recovery runs inside the claude session) ---
foreach ($lf in (Get-AgentLockFiles 'dispatch')) {
    $info = Get-AgentLock $lf.FullName
    if ($info) { Log "found lock: issue #$($info.issueNumber) session=$($info.sessionId) age=$($info.ageMins)min" }
    else        { Log "found lock (unreadable): $($lf.Name)" }
}

# --- deterministic selection (no LLM): full DISPATCH.md pipeline ---
$dispatchable = @(Get-DispatchableIssues -Cap $DefaultCap)
if ($dispatchable.Count -eq 0) { Log "no dispatchable ready issues; skipping (no LLM run)."; exit 0 }
Log "$($dispatchable.Count) dispatchable issue(s) [#$(($dispatchable | ForEach-Object { $_.number }) -join ', #')] -> launching dispatcher."

# --- LLM run ---
$addDir  = if ($WorktreeBase) { @('--add-dir', $WorktreeBase) } else { @() }
$errFile = "$StateDir\dispatch.err"
$out = ('' | claude -p "/dispatch-ready-issues" --permission-mode default --model sonnet @addDir 2> $errFile)
$out | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
$errTxt = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
$txt = (($out -join "`n") + "`n" + $errTxt)

# --- backoff bookkeeping ---
if ($txt -match '(?i)(usage limit|rate limit|limit reached|overloaded|\bquota\b|\b429\b)') {
    $bo = Update-LoopBackoff 'dispatch'
    Log "usage limit detected -> backoff level $($bo.level) for $($bo.minutes) min."
} else {
    Clear-LoopBackoff 'dispatch'
}
