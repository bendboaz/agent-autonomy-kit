# agent-config.ps1 - canonical constants for all agent-ops scripts.
# Dot-source this (or common.ps1, which dot-sources it automatically):
#   . "infra\agent-ops\agent-config.ps1"
#
# Never set GH_APP_PRIVATE_KEY_PATH here — it lives in user-scope env only.

# gh CLI path: hardcoded Windows location; fallback to PATH for cross-platform (CI / pwsh on Linux)
$GH = "C:\Program Files\GitHub CLI\gh.exe"
if (-not (Test-Path $GH)) { $GH = "gh" }

$RepoSlug   = "bendboaz/dnd-session-assistant"
# $RepoRoot resolves to the repo root regardless of where this script is invoked from.
# This script lives at infra/agent-ops/, so two levels up is the repo root.
$RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

$AppId          = "4070567"
$InstallationId = "140736715"

$WorktreeBase = "D:\Users\Boaz\CodeProjects\dnd-wt"
$VenvScripts  = (Join-Path $RepoRoot 'backend\.venv\Scripts')
$BranchPrefix = "claude/agent/issue-"
$DefaultCap   = 1
$StateDir     = (Join-Path $RepoRoot '.claude\agent-state')

$RoleHeaders = @{
    Implementing = "🛠️ **[Implementing Agent]**"
    Reviewing    = "🔎 **[Reviewing Agent]**"
    Human        = "👤 **[Human]**"
}

$Labels = @{
    Ready          = "ready"    # READ-ONLY: set by humans only — never add this label from a script
    InProgress     = "in-progress"
    Blocked        = "blocked"  # READ-ONLY: set by humans only — never add this label from a script
    NeedsAttention = "needs-attention"
    HelpWanted     = "help wanted"
    Meta           = "meta"
}
