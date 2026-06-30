<#
.SYNOPSIS
  Register (or refresh) the three agent-ops Windows scheduled tasks for a consuming repo:
  dispatch (every 2h), babysit (hourly), triage (daily 03:00).

  RUN THIS DIRECTLY IN A TERMINAL -- not via Claude. The deny-hook blocks scheduled-task changes
  inside agent sessions on purpose; schedule setup is a human action.

.PARAMETER RepoRoot   The consuming repo's root (must contain .agent-ops\config.json).
.PARAMETER TaskPrefix Task-name prefix. Default: agentops-<repo-dir>. Tasks: <prefix>-{dispatch,babysit,triage}.
.PARAMETER WhatIf     Print what would be registered without changing anything.

.EXAMPLE
  pwsh install-tasks.ps1 -RepoRoot C:\path\to\your-repo
#>
param(
  [Parameter(Mandatory)][string]$RepoRoot,
  [string]$TaskPrefix,
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path $RepoRoot).Path
if (-not (Test-Path (Join-Path $RepoRoot '.agent-ops\config.json'))) {
  throw "No .agent-ops\config.json under $RepoRoot. Onboard the repo first (see docs/ONBOARDING.md)."
}
if (-not $TaskPrefix) { $TaskPrefix = "agentops-$(Split-Path $RepoRoot -Leaf)" }
$scripts = $PSScriptRoot
$psExe   = (Get-Command powershell.exe).Source
$q       = '"'   # literal double-quote for building the task argument string

Write-Host "Reminder: the consuming repo must be PUBLIC with branch protection on 'main' -- that is"
Write-Host "what makes the App physically unable to merge (see docs/SECURITY.md)."

function New-RepeatTrigger([int]$Hours) {
  # A -Once trigger that repeats every $Hours, effectively indefinitely (the documented
  # .Repetition workaround so the interval reliably sticks on Windows PowerShell).
  $start = (Get-Date).Date.AddHours(8)
  $t = New-ScheduledTaskTrigger -Once -At $start
  $rep = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Hours $Hours) -RepetitionDuration (New-TimeSpan -Days 3650)
  $t.Repetition = $rep.Repetition
  $t
}

$loops = @(
  @{ name = 'dispatch'; wrapper = 'run-dispatch.ps1'; trigger = { New-RepeatTrigger 2 } },
  @{ name = 'babysit';  wrapper = 'run-babysit.ps1';  trigger = { New-RepeatTrigger 1 } },
  @{ name = 'triage';   wrapper = 'run-triage.ps1';   trigger = { New-ScheduledTaskTrigger -Daily -At 3am } }
)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

foreach ($l in $loops) {
  $taskName = "$TaskPrefix-$($l.name)"
  $wrapperPath = Join-Path $scripts $l.wrapper
  $arg = "-NoProfile -ExecutionPolicy Bypass -File $q$wrapperPath$q -RepoRoot $q$RepoRoot$q"
  if ($WhatIf) { Write-Host "[WhatIf] $taskName -> $psExe $arg"; continue }
  $action  = New-ScheduledTaskAction -Execute $psExe -Argument $arg
  $trigger = & $l.trigger
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
  Write-Host "Registered: $taskName"
}
Write-Host "Done. Query with: schtasks /Query /TN $TaskPrefix-* /V /FO LIST"
