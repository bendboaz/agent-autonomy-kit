# run-triage.ps1 - scheduled headless triage for a consuming repo's agent-ops loop.
# Refreshes the backlog-triage report + grooms `help wanted` issues (TRIAGE.md). Captures
# claude stdout/stderr + exit code to <stateDir>/triage.* and retries once on a non-usage-limit
# failure (the nightly run is unattended, so failures must be logged). Registered by install-tasks.ps1.
#   powershell -NoProfile -ExecutionPolicy Bypass -File run-triage.ps1 -RepoRoot <repo root>
param([Parameter(Mandatory)][string]$RepoRoot)
$ErrorActionPreference = 'Continue'
Set-Location $RepoRoot
$env:AGENT_LOOP     = '1'
$env:AGENT_OPS_REPO = $RepoRoot

. "$PSScriptRoot\common.ps1"

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }

$log = "$StateDir\triage.log"
function Log($m) {
    $line = "[{0}] triage: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Write-Host $line
    Add-Content -Path $log -Value $line
}
$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
Log "=== run start (pid $PID, session=$([Environment]::UserName)) ==="

# --- mint App token and verify identity ---
if (-not (Initialize-AgentAuth)) { Log "token mint FAILED; aborting."; exit 1 }
Log "App token minted and identity verified."

# --- run triage headless, with one retry on a transient (non usage-limit) failure ---
$outFile  = "$StateDir\triage.out"
$errFile  = "$StateDir\triage.err"
$limitRx  = '(?i)(usage limit|rate limit|limit reached|overloaded|\bquota\b|\b429\b)'
$max  = 2
$code = -1
for ($attempt = 1; $attempt -le $max; $attempt++) {
    Log "launching claude (attempt $attempt/$max)..."
    $out  = ('' | claude -p "/triage-backlog" --permission-mode default --model sonnet 2> $errFile)
    $code = $LASTEXITCODE
    $out | Set-Content -Path $outFile -Encoding utf8
    $errTxt = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
    $out | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }
    Log "claude exit code: $code"
    if ($code -eq 0) { Log "success."; break }

    # archive the failing attempt for diagnosis
    $arch = "$StateDir\triage.fail_${stamp}_a${attempt}.log"
    "exit=$code`r`n--- STDOUT ---`r`n$($out -join "`r`n")`r`n--- STDERR ---`r`n$errTxt" | Set-Content -Path $arch -Encoding utf8
    Log "attempt $attempt FAILED (exit $code); archived to $arch"

    $combined = (($out -join "`n") + "`n" + $errTxt)
    if ($combined -match $limitRx) { Log "usage/rate limit detected; not retrying."; break }
    if ($attempt -lt $max) { Log "retrying in 30s..."; Start-Sleep -Seconds 30 }
}
Log "=== run end (final exit $code) ==="
exit $code
