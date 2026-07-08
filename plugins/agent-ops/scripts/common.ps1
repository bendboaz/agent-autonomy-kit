# common.ps1 - shared agent-ops helper functions for the agent-ops loops (repo-agnostic).
#
# Usage (interactive session or wrapper script):
#   $env:AGENT_OPS_REPO = "<repo root>"; . "<agent-ops plugin>/scripts/common.ps1"
#
# All functions consume the constants defined in agent-config.ps1 (auto-dot-sourced below).
# Functions that call gh/git accept optional fixture parameters (-Issues, -OpenPRs, etc.)
# so their pure logic can be unit-tested on any platform without a real gh installation.

. "$PSScriptRoot\agent-config.ps1"

# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

function Initialize-AgentAuth {
    <#
    .SYNOPSIS
    Sets App env vars, prepends the configured venv to PATH, mints GH_TOKEN, and
    verifies the resulting gh identity is the configured App bot (not the human).
    Returns $true on success, $false on token-mint failure.
    #>
    $env:GH_APP_ID              = $AppId
    $env:GH_APP_INSTALLATION_ID = $InstallationId
    # GH_APP_PRIVATE_KEY_PATH must already be in the user-scope env — never set here.
    if ($VenvScripts) { $env:PATH = "$VenvScripts;" + $env:PATH }
    $env:GH_TOKEN = (python "$PSScriptRoot\agent_token.py")
    if ($env:GH_TOKEN -notlike 'ghs_*') {
        Write-Warning "Token mint failed (got '$($env:GH_TOKEN)'). Ensure GH_APP_PRIVATE_KEY_PATH is set in user-scope env."
        return $false
    }
    $authOut  = (& $GH auth status 2>&1 | ForEach-Object { "$_" }) -join ' '
    $botRx    = if ($AppBotLogin) { [regex]::Escape($AppBotLogin) } else { '\[bot\]' }
    $botLabel = if ($AppBotLogin) { $AppBotLogin } else { 'a *[bot] account' }
    if ($authOut -notmatch $botRx) {
        Write-Warning "gh auth does not show $botLabel (human or wrong account?): $authOut"
    } else {
        Write-Host "Auth verified: $botLabel."
    }
    return $true
}

function Update-AgentToken {
    <#
    .SYNOPSIS
    Re-mints GH_TOKEN mid-run (token TTL ~10 min).
    #>
    $env:GH_TOKEN = (python "$PSScriptRoot\agent_token.py")
    if ($env:GH_TOKEN -notlike 'ghs_*') { Write-Warning "Token re-mint failed." }
}

# ---------------------------------------------------------------------------
# gh query helpers
# ---------------------------------------------------------------------------

function Get-OpenAgentPRs {
    <#
    .SYNOPSIS
    Returns all open PRs on claude/agent/issue-* branches.
    Pass -PullRequests to inject a fixture (skips the gh call; for tests).
    #>
    param([array]$PullRequests)
    if ($null -eq $PullRequests) {
        $PullRequests = & $GH pr list --repo $RepoSlug --state open `
            --json number,headRefName,labels,body --limit 100 | ConvertFrom-Json
    }
    return @($PullRequests | Where-Object { $_.headRefName -like "$BranchPrefix*" })
}

function Get-LinkedPRForIssue {
    <#
    .SYNOPSIS
    Returns the first open PR linked to IssueNumber, or $null.
    A PR is linked if its head branch equals claude/agent/issue-N or its body
    contains a case-insensitive "closes/fixes/resolves #N" reference.
    #>
    param(
        [int]$IssueNumber,
        [array]$OpenPRs
    )
    return $OpenPRs | Where-Object {
        ($_.headRefName -eq "$BranchPrefix$IssueNumber") -or
        ($_.body -match "(?i)(closes|fixes|resolves)\s+#$IssueNumber\b")
    } | Select-Object -First 1
}

function Get-PriorityRank {
    <#
    .SYNOPSIS
    Returns 0 (high) / 1 (medium) / 2 (low) / 3 (none) for sorting.
    #>
    param($Issue)
    $labelNames = $Issue.labels | ForEach-Object { $_.name }
    if ($labelNames -contains "priority: high")   { return 0 }
    if ($labelNames -contains "priority: medium") { return 1 }
    if ($labelNames -contains "priority: low")    { return 2 }
    return 3
}

function Get-IssueFiles {
    <#
    .SYNOPSIS
    Parses an issue body for its "Relevant files" or "Scope" section and
    returns the repo-relative file paths listed there. Returns @() if absent.
    #>
    param($Issue)
    $body = $Issue.body
    if (-not $body) { return @() }
    # Match a "Relevant files?" or "Scope" heading (any level), capture until next heading or EOF
    if ($body -match '(?im)^#{1,4} *(?:Relevant files?|Scope)[:\s]*$\n([\s\S]+?)(?=\n#|\z)') {
        $section = $Matches[1]
        $files = $section -split '\n' |
                 ForEach-Object { $_.Trim() -replace '^[-*`>]\s*', '' -replace '\s.*', '' } |
                 Where-Object { $_ -match '[\\/.][a-zA-Z]' }
        return @($files)
    }
    return @()
}

function Get-DispatchableIssues {
    <#
    .SYNOPSIS
    Full issue-selection pipeline: fetch ready issues + open PRs, filter
    (not blocked/in-progress/meta/help-wanted, no linked PR), priority-sort,
    apply the concurrency cap, and run the greedy independence filter.
    Returns the batch of issues to dispatch this run (may be empty).

    Pass -Issues and -OpenPRs to inject fixtures (skips gh calls; for tests).
    This is the single source of truth for both the LLM playbook and the
    deterministic gate in run-dispatch.ps1.
    #>
    param(
        [int]$Cap = $DefaultCap,
        [array]$Issues,
        [array]$OpenPRs
    )
    if ($null -eq $Issues) {
        $Issues = & $GH issue list --repo $RepoSlug --state open `
            --label $Labels.Ready --json number,title,labels,body --limit 100 | ConvertFrom-Json
    }
    if ($null -eq $OpenPRs) {
        $OpenPRs = & $GH pr list --repo $RepoSlug --state open `
            --json number,headRefName,labels,body --limit 100 | ConvertFrom-Json
    }

    $openAgentCount = @($OpenPRs | Where-Object { $_.headRefName -like "$BranchPrefix*" }).Count
    if ($openAgentCount -ge $Cap) {
        Write-Verbose "Concurrency cap reached ($openAgentCount/$Cap open agent PRs)."
        return @()
    }
    $slots = $Cap - $openAgentCount

    # Filter: not blocked, not in-progress, not meta, not help-wanted (OPERATIONS.md §2)
    $candidates = @($Issues | Where-Object {
        $n = $_.labels | ForEach-Object { $_.name }
        ($n -notcontains $Labels.Blocked) -and
        ($n -notcontains $Labels.InProgress) -and
        ($n -notcontains $Labels.Meta) -and
        ($n -notcontains $Labels.HelpWanted)
    })

    # Filter out issues that already have an open linked PR
    $dispatchable = @($candidates | Where-Object {
        $null -eq (Get-LinkedPRForIssue -IssueNumber $_.number -OpenPRs $OpenPRs)
    })

    if ($dispatchable.Count -eq 0) { return @() }

    # Sort by priority rank then issue number (lowest first = oldest)
    $ordered = $dispatchable | Sort-Object -Property @(
        @{ Expression = { Get-PriorityRank $_ }; Ascending = $true },
        @{ Expression = { $_.number };            Ascending = $true }
    )

    $batch = @($ordered | Select-Object -First $slots)

    # Greedy independence filter: only include issues whose declared file sets are disjoint.
    # First issue is always included. Issues with no parseable file list are deferred.
    # (DISPATCH.md §3b — this is the single non-deterministic step; the LLM applies judgement
    # for fuzzy file lists; the deterministic form here is conservative: defer when uncertain.)
    $selected     = @()
    $claimedFiles = @()
    foreach ($issue in $batch) {
        $files = Get-IssueFiles $issue
        if ($selected.Count -eq 0) {
            $selected     += $issue
            $claimedFiles += $files
            continue
        }
        if ($files.Count -eq 0) { continue }  # no file info -> defer to a later run
        $overlaps = $files | Where-Object { $claimedFiles -contains $_ }
        if (-not $overlaps) {
            $selected     += $issue
            $claimedFiles += $files
        }
    }

    return $selected
}

function Get-IssueThread {
    <#
    .SYNOPSIS
    Fetches the full comment thread for an issue (per-issue view; the list
    call's comments field is unreliable per TRIAGE.md §2.4).
    #>
    param([int]$Number)
    $issue = & $GH issue view $Number --repo $RepoSlug --json number,comments | ConvertFrom-Json
    return $issue.comments
}

# ---------------------------------------------------------------------------
# PR attention classification
# ---------------------------------------------------------------------------

function Get-PRNeedsAttention {
    <#
    .SYNOPSIS
    Pure classifier: returns $true if the given detailed PR object (with
    mergeStateStatus, statusCheckRollup, reviewDecision, comments fields)
    needs a babysitter round this run.
    This function never calls gh — suitable for fixture-based unit tests.
    #>
    param($PR)
    $badConclusions = @('FAILURE','TIMED_OUT','ERROR','CANCELLED','ACTION_REQUIRED','STARTUP_FAILURE')
    $behind  = $PR.mergeStateStatus -in @('BEHIND','DIRTY','UNSTABLE')
    $failed  = @($PR.statusCheckRollup | Where-Object { $_.conclusion -in $badConclusions }).Count -gt 0
    $changes = $PR.reviewDecision -eq 'CHANGES_REQUESTED'

    # Unaddressed review: latest [Reviewing Agent] comment newer than latest non-reviewer reply
    $lastRev   = $PR.comments | Where-Object { $_.body -match '\[Reviewing Agent\]' } |
                 Sort-Object createdAt | Select-Object -Last 1
    $lastReply = $PR.comments | Where-Object { $_.body -notmatch '\[Reviewing Agent\]' } |
                 Sort-Object createdAt | Select-Object -Last 1
    $reviewOpen = $false
    if ($lastRev) {
        if (-not $lastReply) { $reviewOpen = $true }
        elseif ([datetime]$lastRev.createdAt -gt [datetime]$lastReply.createdAt) { $reviewOpen = $true }
    }

    return $behind -or $failed -or $changes -or $reviewOpen
}

function Test-PRBabysitEligible {
    <#
    .SYNOPSIS
    Pure predicate: is this PR (coarse list fields only) in babysit's scope —
    on an agent-dispatch branch, or explicitly opted in via the babysit label
    ($Labels.Babysit) — and not already flagged needs-attention?
    Like the rest of common.ps1's selection logic (e.g. Get-LinkedPRForIssue),
    this assumes $BranchPrefix/$Labels are already loaded by agent-config.ps1;
    it never calls gh itself, so it's fixture-testable once those are set.
    #>
    param($PR)
    $inScope = ($PR.headRefName -like "$BranchPrefix*") -or ($PR.labels.name -contains $Labels.Babysit)
    return $inScope -and ($PR.labels.name -notcontains $Labels.NeedsAttention)
}

function Get-PRsNeedingAttention {
    <#
    .SYNOPSIS
    Lists open PRs in babysit's scope (agent-dispatch branch, or opted in via
    the babysit label; excluding needs-attention) that need a babysitter
    round. Fetches per-PR detail for the classification check.
    Pass -PullRequests to inject the coarse PR list fixture (skips gh pr list).
    #>
    param([array]$PullRequests)
    if ($null -eq $PullRequests) {
        $PullRequests = & $GH pr list --repo $RepoSlug --state open `
            --json number,headRefName,labels --limit 100 | ConvertFrom-Json
    }
    $agent = @($PullRequests | Where-Object { Test-PRBabysitEligible -PR $_ })
    if ($agent.Count -eq 0) { return @() }

    $need = @()
    foreach ($p in $agent) {
        $d = & $GH pr view $p.number --repo $RepoSlug `
            --json number,headRefName,mergeStateStatus,statusCheckRollup,reviewDecision,comments |
            ConvertFrom-Json
        if (Get-PRNeedsAttention -PR $d) { $need += $d }
    }
    return $need
}

# ---------------------------------------------------------------------------
# Worktree management
# ---------------------------------------------------------------------------

function New-AgentWorktree {
    <#
    .SYNOPSIS
    Creates a worktree at $WorktreeBase\issue-N on a new branch off origin/main.
    Returns the worktree path on success, $null on failure.
    #>
    param([int]$IssueNumber)
    $branch       = "$BranchPrefix$IssueNumber"
    $worktreePath = (Join-Path $WorktreeBase "issue-$IssueNumber")
    git -C $RepoRoot fetch origin main
    if ($LASTEXITCODE -ne 0) { Write-Warning "fetch origin main failed."; return $null }
    git -C $RepoRoot worktree add $worktreePath -b $branch origin/main
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Worktree creation failed for #$IssueNumber."
        return $null
    }
    return $worktreePath
}

function Remove-AgentWorktree {
    <#
    .SYNOPSIS
    Removes the worktree for issue N. Logs a warning (not an error) if git fails;
    the caller should flag for manual cleanup rather than retrying.
    #>
    param([int]$IssueNumber)
    $worktreePath = (Join-Path $WorktreeBase "issue-$IssueNumber")
    Set-Location $RepoRoot
    git -C $RepoRoot worktree remove $worktreePath --force
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Worktree remove failed for issue-$IssueNumber; may need manual cleanup."
    }
}

# ---------------------------------------------------------------------------
# Comment posting
# ---------------------------------------------------------------------------

function Send-AgentComment {
    <#
    .SYNOPSIS
    Posts a role-headed comment to an issue or PR via gh --body-file, using
    the fixed no-space temp path to avoid PowerShell quoting issues.
    Accepts body as a string (-Body) or a pre-written file path (-BodyPath).
    The role header is prepended automatically if the body doesn't already
    start with one (detection via leading emoji).
    #>
    param(
        [ValidateSet('issue','pr')][string]$Type,
        [int]$Number,
        [string]$Role = 'Implementing',
        [string]$Body,
        [string]$BodyPath
    )
    $header = if ($RoleHeaders.ContainsKey($Role)) { $RoleHeaders[$Role] } else { $RoleHeaders.Implementing }

    if ($BodyPath -and (Test-Path $BodyPath)) {
        $rawBody = [System.IO.File]::ReadAllText($BodyPath, [System.Text.Encoding]::UTF8)
    } elseif ($Body) {
        $rawBody = $Body
    } else {
        Write-Warning "Send-AgentComment: neither -Body nor a valid -BodyPath provided."
        return
    }

    # Prepend header only when the body doesn't already start with one of the role headers
    $alreadyHasHeader = $RoleHeaders.Values | Where-Object { $rawBody.TrimStart().StartsWith($_) }
    if (-not $alreadyHasHeader) {
        $rawBody = "$header`n`n$rawBody"
    }

    $tmp = "$env:TEMP\cc-comment.txt"
    [System.IO.File]::WriteAllText($tmp, $rawBody, [System.Text.Encoding]::UTF8)

    if ($Type -eq 'issue') {
        & $GH issue comment $Number --repo $RepoSlug --body-file $tmp
    } else {
        & $GH pr comment $Number --repo $RepoSlug --body-file $tmp
    }

    Remove-Item $tmp -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Local verification
# ---------------------------------------------------------------------------

function Invoke-LocalVerify {
    <#
    .SYNOPSIS
    Runs the required local checks in a worktree: npm ci, tsc, build, test,
    and optionally pytest. Returns $true if all pass.
    #>
    param([string]$WorktreePath, [switch]$IncludeBackend)
    $prev = Get-Location
    Set-Location $WorktreePath
    npm ci
    if ($LASTEXITCODE -ne 0) { Set-Location $prev; return $false }
    npx tsc --noEmit
    if ($LASTEXITCODE -ne 0) { Set-Location $prev; return $false }
    npm run build
    if ($LASTEXITCODE -ne 0) { Set-Location $prev; return $false }
    npm test
    if ($LASTEXITCODE -ne 0) { Set-Location $prev; return $false }
    if ($IncludeBackend) {
        Set-Location (Join-Path $WorktreePath 'backend')
        pytest
        if ($LASTEXITCODE -ne 0) { Set-Location $prev; return $false }
    }
    Set-Location $prev
    return $true
}

# ---------------------------------------------------------------------------
# Backoff (dispatch / babysit loops)
# ---------------------------------------------------------------------------

function New-BackoffMinutes {
    <#
    .SYNOPSIS
    Pure function: returns the number of minutes to back off for a given level.
    Level 1->15, 2->30, 3->60, 4->120, 5+->240 (capped).
    Extracted from the inline logic in run-dispatch.ps1 / run-babysit.ps1.
    #>
    param([int]$Level)
    return [int][Math]::Min(15 * [Math]::Pow(2, [Math]::Max(1, $Level) - 1), 240)
}

function Test-LoopBackoff {
    <#
    .SYNOPSIS
    Returns $true if the named loop is currently in its backoff window.
    #>
    param([string]$Loop)
    $backoffFile = (Join-Path $StateDir "$Loop.backoff")
    if (-not (Test-Path $backoffFile)) { return $false }
    try {
        $b = Get-Content $backoffFile -Raw | ConvertFrom-Json
        return ($b -and [datetime]$b.until -gt (Get-Date))
    } catch { return $false }
}

# Called by .claude/run-dispatch.ps1 and .claude/run-babysit.ps1 (gitignored wrappers).
function Get-LoopBackoffInfo {
    param([string]$Loop)
    $backoffFile = (Join-Path $StateDir "$Loop.backoff")
    if (-not (Test-Path $backoffFile)) { return $null }
    try { return Get-Content $backoffFile -Raw | ConvertFrom-Json } catch { return $null }
}

function Update-LoopBackoff {
    <#
    .SYNOPSIS
    Increments the backoff level for a loop and writes the new "until" time.
    Returns a hashtable with .level and .minutes.
    #>
    param([string]$Loop)
    $backoffFile = (Join-Path $StateDir "$Loop.backoff")
    $level = 0
    if (Test-Path $backoffFile) {
        try { $level = [int]((Get-Content $backoffFile -Raw | ConvertFrom-Json).level) } catch {}
    }
    $level = [Math]::Min($level + 1, 5)
    $mins  = New-BackoffMinutes $level
    @{ until = (Get-Date).AddMinutes($mins).ToString('o'); level = $level } |
        ConvertTo-Json -Compress | Set-Content $backoffFile -Encoding ascii
    return @{ level = $level; minutes = $mins }
}

function Clear-LoopBackoff {
    param([string]$Loop)
    $backoffFile = (Join-Path $StateDir "$Loop.backoff")
    if (Test-Path $backoffFile) { Remove-Item $backoffFile -Force }
}

# ---------------------------------------------------------------------------
# Lock files (dispatch only)
# ---------------------------------------------------------------------------

function Get-AgentLockFiles {
    <#
    .SYNOPSIS
    Returns FileInfo objects for all dispatch lock files.
    #>
    param([string]$Loop = 'dispatch')
    return @(Get-ChildItem (Join-Path $StateDir "$Loop-lock-*.json") -ErrorAction SilentlyContinue)
}

function Get-AgentLock {
    <#
    .SYNOPSIS
    Reads one lock file and returns a hashtable with issueNumber, sessionId,
    ageMins, and path. Returns $null if the file is unreadable.
    #>
    param([string]$Path)
    try {
        $l   = Get-Content $Path -Raw | ConvertFrom-Json
        $age = [int]((Get-Date) - [datetime]$l.startedAt).TotalMinutes
        return @{ issueNumber = $l.issueNumber; sessionId = $l.sessionId; ageMins = $age; path = $Path }
    } catch { return $null }
}

function Set-AgentLock {
    param([string]$Loop = 'dispatch', [int]$IssueNumber, [string]$SessionId)
    $lockFile = (Join-Path $StateDir "$Loop-lock-$IssueNumber.json")
    @{ issueNumber = $IssueNumber; sessionId = $SessionId; startedAt = (Get-Date).ToString('o') } |
        ConvertTo-Json -Compress | Set-Content $lockFile -Encoding ascii
}

function Remove-AgentLock {
    param([string]$Loop = 'dispatch', [int]$IssueNumber)
    $lockFile = (Join-Path $StateDir "$Loop-lock-$IssueNumber.json")
    if (Test-Path $lockFile) { Remove-Item $lockFile -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# Failure notifications (unattended loops have no one watching stdout)
# ---------------------------------------------------------------------------

function Send-WindowsToast {
    <#
    .SYNOPSIS
    Fires a local Windows toast via the built-in WinRT APIs (no module install).
    Windows-only; no-ops on other platforms (CI runs Pester on ubuntu-latest).
    Never throws - a notification failure must not fail the calling loop.
    #>
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Message)
    if ($IsWindows -eq $false) { return }
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        # Well-known AUMID for Windows PowerShell itself - lets an unpackaged script
        # raise a toast without registering a shortcut/app identity.
        $appId    = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        $template  = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $textNodes = $template.GetElementsByTagName('text')
        $textNodes.Item(0).AppendChild($template.CreateTextNode($Title))   | Out-Null
        $textNodes.Item(1).AppendChild($template.CreateTextNode($Message)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch {
        Write-Warning "Windows toast failed: $_"
    }
}

function Send-ClaudePhonePush {
    <#
    .SYNOPSIS
    Best-effort phone push: spins up a tiny headless `claude` session whose only
    job is to call the PushNotification tool. Requires claude to be able to log
    in itself, so this is a secondary channel - it will silently no-op for the
    exact failure mode where claude can't start a session at all (e.g. a stale
    CLI login), which is why Send-WindowsToast is the guaranteed channel.
    Bounded by a timeout so a hung claude invocation can't block the loop.
    #>
    param([Parameter(Mandatory)][string]$Message)
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { return }
    try {
        $prompt = "Call the PushNotification tool with status proactive and this exact message: $Message. Do not do anything else."
        $job = Start-Job -ScriptBlock {
            param($p) claude -p $p --permission-mode auto --remote-control 2>&1 | Out-Null
        } -ArgumentList $prompt
        Wait-Job $job -Timeout 45 | Out-Null
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "Phone push attempt failed: $_"
    }
}

function Send-LoopFailureNotification {
    <#
    .SYNOPSIS
    Tells the human an unattended loop run failed: a guaranteed local Windows
    toast, plus a best-effort phone push. Never throws - call this from a
    catch-adjacent path in a wrapper script, not the other way around.
    #>
    param([Parameter(Mandatory)][string]$Loop, [Parameter(Mandatory)][string]$Detail)
    $clipped = if ($Detail.Length -gt 140) { $Detail.Substring(0, 140) + '...' } else { $Detail }
    $title   = "agent-ops: $Loop failed ($RepoSlug)"
    Send-WindowsToast -Title $title -Message $clipped
    Send-ClaudePhonePush -Message "$title -- $clipped"
}
