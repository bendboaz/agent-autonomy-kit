# run-babysit.ps1 - scheduled headless PR babysitter for a consuming repo's agent-ops loop.
# Scope: open `<branchPrefix>*` PRs (the autonomous lane; safe to touch unattended). Cost-aware:
# checks deterministically (pure gh) whether any agent PR actually needs work and only launches
# `claude -p` if so. Exponential backoff on usage limits. Registered per-repo by install-tasks.ps1.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File run-babysit.ps1 -RepoRoot <repo root>
param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference = 'Continue'
Set-Location $RepoRoot
$env:AGENT_LOOP     = '1'
$env:AGENT_OPS_REPO = $RepoRoot

. "$PSScriptRoot\common.ps1"

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
function Log($m) { Write-Host ("[{0}] babysit: {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

# --- backoff gate ---
if (Test-LoopBackoff 'babysit') {
    $b = Get-LoopBackoffInfo 'babysit'
    Log "in backoff until $($b.until) (level $($b.level)); skipping."
    exit 0
}

# --- mint App token ---
if (-not (Initialize-AgentAuth)) { Log "token mint failed; skipping."; exit 1 }

# --- preflight: prune stale worktrees + ensure worktree base dir ---
$cleanupScript = "$PSScriptRoot\cleanup.ps1"
if (Test-Path $cleanupScript) { & $cleanupScript -Repo $RepoSlug -RepoRoot $RepoRoot } else { Log "cleanup.ps1 not found; skipping stale-worktree prune." }
if ($WorktreeBase -and -not (Test-Path $WorktreeBase)) {
    New-Item -ItemType Directory -Force -Path $WorktreeBase | Out-Null
    Log "created worktree base dir."
}

# --- deterministic 'needs attention' check (no LLM) ---
$need = @(Get-PRsNeedingAttention)
if ($need.Count -eq 0) { Log "all agent PR(s) clean/up-to-date; skipping (no LLM run)."; exit 0 }
$prs = ($need | ForEach-Object { "#$($_.number)" }) -join ', '
Log "$($need.Count) PR(s) need attention: $prs -> launching babysitter."

# --- LLM run ---
$addDir  = if ($WorktreeBase) { @('--add-dir', $WorktreeBase) } else { @() }
$errFile = "$StateDir\babysit.err"
$out = ('' | claude -p "/babysit-prs" --permission-mode auto --model sonnet @addDir 2> $errFile)
$out | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
$errTxt = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
$txt = (($out -join "`n") + "`n" + $errTxt)

# --- backoff bookkeeping ---
if ($txt -match '(?i)(usage limit|rate limit|limit reached|overloaded|\bquota\b|\b429\b)') {
    $bo = Update-LoopBackoff 'babysit'
    Log "usage limit detected -> backoff level $($bo.level) for $($bo.minutes) min."
} else {
    Clear-LoopBackoff 'babysit'
}
