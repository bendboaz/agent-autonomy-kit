<#
.SYNOPSIS
  Prune finished agent branches + worktrees for a consuming repo's agent-ops loop.

.DESCRIPTION
  Idempotent and safe. Removes ONLY branches/worktrees whose PR is MERGED or CLOSED and
  that have NO open PR. It NEVER touches `main`, the currently checked-out branch, or any
  branch that still has an open PR -- so mid-flight work (a branch whose PR is still open,
  or a branch that has no PR yet) is always preserved.

  It keys off PR *state*, not git ancestry, so it works regardless of merge strategy
  (squash / rebase / merge commits all handled).

  Remote branches: this script prunes LOCAL worktrees + branches and stale remote-tracking
  refs (`fetch --prune`). Deleting the actual remote head branch on merge is best handled by
  the repo setting "Automatically delete head branches" (Settings -> General). See OPERATIONS.md.

.PARAMETER DryRun
  Print what would be removed without changing anything. Always safe to run first.

.EXAMPLE
  pwsh cleanup.ps1 -DryRun     # from the agent-ops plugin's scripts/ dir, inside the repo
  pwsh cleanup.ps1
#>
param(
  [string]$Repo,
  [string]$RepoRoot,
  [switch]$DryRun
)

# When -Repo isn't passed (a standalone orchestrator run), load identity from the repo's
# .agent-ops/config.json. The loader resolves the repo from $env:AGENT_OPS_REPO or the cwd
# and sets $RepoSlug + $RepoRoot. The run-babysit.ps1 wrapper passes both explicitly.
if (-not $Repo) {
  . "$PSScriptRoot\agent-config.ps1"
  $Repo = $RepoSlug
}

# gh is not always on PATH; fall back to PATH elsewhere.
$gh = "C:\Program Files\GitHub CLI\gh.exe"
if (-not (Test-Path $gh)) { $gh = "gh" }
function Step($m) { Write-Host "[cleanup] $m" }

# 0. Prune stale remote-tracking refs and worktree admin entries (dirs deleted out-of-band).
git -C $RepoRoot fetch --prune | Out-Null
if ($LASTEXITCODE -ne 0) { Step "WARNING: 'git fetch --prune' failed (exit $LASTEXITCODE); continuing with possibly stale remote info." }
git -C $RepoRoot worktree prune

# 1. Classify branches by PR state. "finished" = has a MERGED/CLOSED PR and NO open PR.
# --limit 500: gh defaults to 30, which would hide older finished branches on a busy repo.
$prs = & $gh pr list --repo $Repo --state all --limit 500 --json headRefName,state | ConvertFrom-Json
$openHeads     = @($prs | Where-Object { $_.state -eq 'OPEN' } | ForEach-Object { $_.headRefName })
$finishedHeads = @(
  $prs | Where-Object { $_.state -eq 'MERGED' -or $_.state -eq 'CLOSED' } |
         ForEach-Object { $_.headRefName }
) | Where-Object { $openHeads -notcontains $_ } | Select-Object -Unique

$current = (git -C $RepoRoot rev-parse --abbrev-ref HEAD).Trim()

# 2. Remove worktrees whose checked-out branch is finished.
$blocks = ((git -C $RepoRoot worktree list --porcelain) -join "`n") -split "`n`n"
foreach ($b in $blocks) {
  if ($b -notmatch 'worktree (.+)') { continue }
  $path   = $Matches[1].Trim()
  $branch = if ($b -match 'branch refs/heads/(.+)') { $Matches[1].Trim() } else { $null }
  if ($branch -and ($finishedHeads -contains $branch)) {
    if ($DryRun) { Step "would remove worktree: $path  [$branch]" }
    else { Step "removing worktree: $path  [$branch]"; git -C $RepoRoot worktree remove $path --force }
  }
}

# 3. Delete local branches that are finished (skip main and the current branch).
$localBranches = (git -C $RepoRoot branch --format '%(refname:short)') |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ }
foreach ($lb in $localBranches) {
  if ($lb -eq 'main' -or $lb -eq $current) { continue }
  if ($finishedHeads -contains $lb) {
    if ($DryRun) { Step "would delete local branch: $lb" }
    else {
      Step "deleting local branch: $lb"
      git -C $RepoRoot branch -D $lb | Out-Null
      if ($LASTEXITCODE -ne 0) { Step "WARNING: failed to delete local branch '$lb' (exit $LASTEXITCODE)." }
    }
  }
}

if ($DryRun) { Step "done (dry run; no changes made)." } else { Step "done." }
if ($current -ne 'main') { Step "note: current branch '$current' was skipped; run from 'main' to prune it once its PR merges." }
