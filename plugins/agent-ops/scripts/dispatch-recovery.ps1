# dispatch-recovery.ps1 - dead-agent recovery scan entry point (DISPATCH.md Sec 1c).
#
# Thin CLI wrapper: loads the engine for the target repo, then runs the scan. The actual
# detection/recovery logic lives in common.ps1's Invoke-DispatchRecovery (plus its pure
# helpers Test-SessionActive / Test-LockStillAlive / Get-LockRecoveryAction) so it is
# unit-testable with injected fixtures -- see tests/common.Tests.ps1.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File dispatch-recovery.ps1 [-RepoRoot <repo root>]
#
# Usually run with no arguments from inside a dispatch-ready-issues skill session, after
# Initialize-AgentAuth has already set $env:AGENT_OPS_REPO and minted GH_TOKEN -- the config
# loader (dot-sourced below via common.ps1) falls back to $env:AGENT_OPS_REPO / the current
# directory when -RepoRoot is omitted.
param([string]$RepoRoot)

# -RepoRoot overwrites $env:AGENT_OPS_REPO for the rest of the process (matching the
# run-*.ps1 wrappers, which run one-shot). Pass it only from a caller that owns that env
# var; the normal in-session path omits it and inherits the value Initialize-AgentAuth set.
if ($RepoRoot) { $env:AGENT_OPS_REPO = $RepoRoot }
. "$PSScriptRoot\common.ps1"

Invoke-DispatchRecovery
