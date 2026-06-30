<#
.SYNOPSIS
  Remove the agent-ops scheduled tasks for a consuming repo. Run DIRECTLY IN A TERMINAL (not via Claude;
  the deny-hook blocks scheduled-task changes inside agent sessions).
.PARAMETER RepoRoot   The consuming repo's root (used to derive the default task prefix).
.PARAMETER TaskPrefix Same defaulting as install-tasks.ps1 (agentops-<repo-dir>).
.PARAMETER WhatIf     Print what would be removed without changing anything.
.EXAMPLE
  pwsh uninstall-tasks.ps1 -RepoRoot C:\path\to\your-repo
#>
param(
  [Parameter(Mandatory)][string]$RepoRoot,
  [string]$TaskPrefix,
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path $RepoRoot).Path
if (-not $TaskPrefix) { $TaskPrefix = "agentops-$(Split-Path $RepoRoot -Leaf)" }

foreach ($name in 'dispatch','babysit','triage') {
  $taskName = "$TaskPrefix-$name"
  $exists = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if (-not $exists) { Write-Host "not found: $taskName"; continue }
  if ($WhatIf) { Write-Host "[WhatIf] would unregister: $taskName"; continue }
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  Write-Host "Removed: $taskName"
}
