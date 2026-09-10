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
    ageMins, path, worktreePath, and branch. Returns $null if the file is unreadable.
    #>
    param([string]$Path)
    try {
        $l   = Get-Content $Path -Raw | ConvertFrom-Json
        $age = [int]((Get-Date) - [datetime]$l.startedAt).TotalMinutes
        return @{
            issueNumber  = $l.issueNumber
            sessionId    = $l.sessionId
            ageMins      = $age
            path         = $Path
            worktreePath = $l.worktreePath
            branch       = $l.branch
        }
    } catch { return $null }
}

function Set-AgentLock {
    <#
    .SYNOPSIS
    Writes (or overwrites) a dispatch lock file for IssueNumber. WorktreePath and
    Branch let a later dead-agent recovery scan (Invoke-DispatchRecovery) push an
    orphaned branch and remove its worktree without re-deriving either from disk.
    #>
    param(
        [string]$Loop = 'dispatch',
        [int]$IssueNumber,
        [string]$SessionId,
        [string]$WorktreePath,
        [string]$Branch
    )
    $lockFile = (Join-Path $StateDir "$Loop-lock-$IssueNumber.json")
    @{
        issueNumber  = $IssueNumber
        sessionId    = $SessionId
        startedAt    = (Get-Date).ToString('o')
        worktreePath = $WorktreePath
        branch       = $Branch
    } | ConvertTo-Json -Compress | Set-Content $lockFile -Encoding ascii
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
    # Must stay `-eq $false`, not `-not $IsWindows`: on Windows PowerShell 5.1 - the
    # runtime these wrappers actually run under - $IsWindows doesn't exist and reads
    # as $null. `-not $null` is $true, which would skip the toast in production.
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

    $Message is failure text pulled from a prior claude run's own stdout/stderr,
    so it is untrusted input to this new session's prompt. --tools PushNotification
    caps the blast radius to "at worst, sends a weird notification" - the session
    has no other tool available regardless of what the prompt talks it into. The
    job's environment is scrubbed of App/GH credentials for the same reason: this
    session should never be able to act with the App's identity, injected or not.
    #>
    param([Parameter(Mandatory)][string]$Message)
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { return }
    try {
        $prompt = "Call the PushNotification tool with status proactive and this exact message: $Message. Do not do anything else."
        $job = Start-Job -ScriptBlock {
            param($p)
            Remove-Item Env:\GH_TOKEN, Env:\GH_APP_ID, Env:\GH_APP_INSTALLATION_ID, Env:\AGENT_LOOP -ErrorAction SilentlyContinue
            claude -p $p --permission-mode auto --remote-control --tools PushNotification | Out-Null
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
    # PushNotification's own contract caps messages at ~200 chars (mobile OSes
    # truncate) - title + separator + the 140-char detail clip can exceed that,
    # so clip the combined phone-push payload separately from the toast message.
    $phoneMsg = "$title -- $clipped"
    if ($phoneMsg.Length -gt 190) { $phoneMsg = $phoneMsg.Substring(0, 187) + '...' }
    Send-ClaudePhonePush -Message $phoneMsg
}

# ---------------------------------------------------------------------------
# Dead-agent recovery (DISPATCH.md Sec 1c)
# ---------------------------------------------------------------------------

function Get-CurrentSessionId {
    <#
    .SYNOPSIS
    Best-effort: returns the session ID (filename stem) of the most recently
    modified transcript under $TranscriptDir, or $null when TranscriptDir isn't
    configured or has no transcripts yet.

    Called at claim time (DISPATCH.md Sec 5.1), right after the worktree is
    created, so a later Invoke-DispatchRecovery scan can tell whether the
    session that claimed an issue is still alive. Heuristic: if multiple
    Claude Code sessions for this project are active at once, this can
    attribute the wrong session ID to a lock -- Test-LockStillAlive's 2-hour
    hard TTL is the safety net for when that happens.
    #>
    if (-not $TranscriptDir -or -not (Test-Path $TranscriptDir)) { return $null }
    $latest = Get-ChildItem $TranscriptDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { return $null }
    return [System.IO.Path]::GetFileNameWithoutExtension($latest.Name)
}

function Test-SessionActive {
    <#
    .SYNOPSIS
    Returns $true if SessionId's transcript under $TranscriptDir was modified
    within the last 15 minutes. Returns $false (treat as dead; defer to
    Test-LockStillAlive's 2-hour hard TTL) when SessionId is empty,
    $TranscriptDir isn't configured, or the transcript can't be found.
    #>
    param([string]$SessionId)
    if (-not $SessionId -or -not $TranscriptDir) { return $false }
    $transcript = Join-Path $TranscriptDir "$SessionId.jsonl"
    if (-not (Test-Path $transcript)) { return $false }
    $age = (Get-Date) - (Get-Item $transcript).LastWriteTime
    return $age.TotalMinutes -lt 15
}

function Test-LockStillAlive {
    <#
    .SYNOPSIS
    Pure guard: a lock is still considered alive only if its session is
    active (Test-SessionActive) AND the lock itself is under 2 hours old.
    The 2-hour hard TTL is a deliberate override -- it fires recovery even
    for a lock whose liveness check looks "alive", covering the case where
    Get-CurrentSessionId attributed the wrong session ID at claim time.
    #>
    param([bool]$Alive, [int]$AgeMinutes)
    return ($Alive -and $AgeMinutes -lt 120)
}

function Get-LockRecoveryAction {
    <#
    .SYNOPSIS
    Pure classifier for a lock already known to be dead (see
    Test-LockStillAlive): decides what Invoke-DispatchRecovery should do with
    it.
      'clear-lock-only' - an open PR already exists for the branch (the agent
                           likely finished and the dispatcher's normal
                           PR-open path just hasn't cleared the lock yet);
                           remove the stale lock only.
      'salvage'         - no existing PR, and the branch has commits; open a
                           draft PR and flag needs-attention.
      'unclaim'         - no existing PR, and the branch has no commits;
                           clear in-progress so the issue can be re-dispatched.
    Never touches gh/git/disk -- the caller computes HasExistingPR/HasCommits
    first and passes them in.
    #>
    param([bool]$HasExistingPR, [bool]$HasCommits)
    if ($HasExistingPR) { return 'clear-lock-only' }
    if ($HasCommits) { return 'salvage' }
    return 'unclaim'
}

function Invoke-DispatchRecovery {
    <#
    .SYNOPSIS
    Dead-agent recovery scan (DISPATCH.md Sec 1c). For every dispatch lock
    file: skip it if the session is still alive and the lock is fresh
    (Test-LockStillAlive); otherwise decide via Get-LockRecoveryAction
    whether the locking session already finished (an open PR exists -- clear
    the stale lock only), salvaged a draft PR (dead + commits on the
    branch), or should be silently unclaimed (dead + no commits). Always
    removes the worktree and the lock file for anything not left alone.

    Pass -LockFiles to inject a fixture list (skips the Get-AgentLockFiles
    scan; for tests). Never calls gh/git when the (possibly injected) list
    is empty, and short-circuits before any gh/git call for locks whose
    session is still alive.
    #>
    param([array]$LockFiles)

    if ($null -eq $LockFiles) { $LockFiles = Get-AgentLockFiles 'dispatch' }
    if ($LockFiles.Count -eq 0) { return }

    Write-Host "[dispatch-recovery] Found $($LockFiles.Count) lock file(s); scanning for dead agents."

    foreach ($lf in $LockFiles) {
        $lock = Get-AgentLock $lf.FullName
        if (-not $lock) {
            Write-Warning "[dispatch-recovery] Cannot parse $($lf.Name); removing corrupt lock."
            Remove-Item $lf.FullName -ErrorAction SilentlyContinue
            continue
        }

        $n     = $lock.issueNumber
        $alive = Test-SessionActive $lock.sessionId

        if (Test-LockStillAlive -Alive $alive -AgeMinutes $lock.ageMins) {
            Write-Host "[dispatch-recovery] Issue #${n}: session $($lock.sessionId) still active ($($lock.ageMins)min); skipping."
            continue
        }

        Write-Host "[dispatch-recovery] Issue #${n}: dead agent (session=$($lock.sessionId), age=$($lock.ageMins)min)"

        # If a PR already exists for this branch, the agent may have finished; just clean the lock.
        $prListRaw = & $GH pr list --repo $RepoSlug --head $lock.branch --state open --json number
        if ($LASTEXITCODE -ne 0) {
            # Can't confirm whether a PR already exists; proceeding could open a duplicate.
            # Skip this lock and let the next run retry once gh is reachable again.
            Write-Warning "[dispatch-recovery] Issue #${n}: 'gh pr list' failed (exit $LASTEXITCODE); skipping this lock to avoid a duplicate PR (will retry next run)."
            continue
        }
        # Assign the parsed result to a variable *before* wrapping in @(): in PS 5.1
        # `@(<pipeline> | ConvertFrom-Json)` counts an empty JSON array `[]` as one
        # element (the non-enumerated empty array), which would send every dead lock
        # down the clear-lock-only path. `@($var)` on an already-materialised empty
        # array is correctly zero-length.
        $prParsed   = $prListRaw | ConvertFrom-Json
        $existingPR = @($prParsed)

        # $commits is initialised here, not inside the branch below: PS 5.1 does not scope
        # foreach bodies, so a leftover value from a prior iteration must not leak into
        # Get-LockRecoveryAction if neither sub-branch reassigns it.
        $commits = @()
        $wt = $lock.worktreePath
        if ($existingPR.Count -eq 0 -and $wt -and (Test-Path $wt)) {
            # -is [string] guards against native-command stderr arriving as ErrorRecord
            # objects in the array (PS 5.1), which would inflate the count and misclassify
            # an empty branch as having commits.
            $commits = @(git -C $wt log "origin/main..HEAD" --oneline | Where-Object { $_ -is [string] -and $_ })
            if ($LASTEXITCODE -ne 0) {
                # An invalid/corrupt worktree makes git fail. Rather than let the empty result
                # take the "no commits" path and unclaim a branch that may hold real work, skip
                # this lock entirely and let the next dispatch run retry the recovery -- the same
                # way the git-push / gh-pr-create failures below are handled.
                Write-Warning "[dispatch-recovery] Issue #${n}: 'git log' failed in $wt (exit $LASTEXITCODE); skipping this lock, will retry next run."
                continue
            }
        }

        $action = Get-LockRecoveryAction -HasExistingPR ($existingPR.Count -gt 0) -HasCommits ($commits.Count -gt 0)

        switch ($action) {
            'clear-lock-only' {
                # An open PR exists, so the branch is pushed and safe. Drop only the stale
                # lock and `continue` -- deliberately leaving the worktree, since the PR may
                # still be in review and the worktree wanted; cleanup.ps1 (DISPATCH.md Sec 1b,
                # runs just before this scan) reaps it once the PR is merged/closed.
                Write-Host "[dispatch-recovery] Issue #${n}: PR #$($existingPR[0].number) already open; removing stale lock only."
                Remove-Item $lf.FullName -ErrorAction SilentlyContinue
                continue
            }
            'salvage' {
                Write-Host "[dispatch-recovery] Issue #${n}: $($commits.Count) commit(s) found; salvaging as draft PR."

                git -C $wt push origin $lock.branch
                if ($LASTEXITCODE -ne 0) {
                    # Without the branch on the remote, the draft PR creation below would fail
                    # confusingly. Skip this lock (leave it + the worktree in place) so the next
                    # dispatch run retries the recovery rather than half-completing it.
                    Write-Warning "[dispatch-recovery] Issue #${n}: 'git push' failed (exit $LASTEXITCODE); skipping PR creation and leaving the lock for the next run to retry."
                    continue
                }

                $tmp  = Join-Path $StateDir 'dispatch-recovery-comment.txt'
                $body = @"
$($RoleHeaders.Implementing)

Orphaned-branch recovery: the implementing subagent for issue #$n failed or was interrupted mid-run.
$($commits.Count) commit(s) were found on this branch; opening as a draft PR for human review.

Action needed: review the draft, continue or close, then clear needs-attention when done.
"@
                [System.IO.File]::WriteAllText($tmp, $body, [System.Text.Encoding]::UTF8)

                $prUrl = & $GH pr create --repo $RepoSlug --head $lock.branch --base main --draft `
                    --title "[DRAFT] Issue #${n}: orphaned by interrupted agent" `
                    --body-file $tmp
                if ($LASTEXITCODE -ne 0) {
                    # PR creation failed: the branch is pushed but unmerged. Leave the lock and
                    # worktree in place so the next run retries, rather than deleting them below
                    # and silently stranding the orphaned branch with no PR.
                    Write-Warning "[dispatch-recovery] Issue #${n}: 'gh pr create' failed (exit $LASTEXITCODE); leaving the lock for the next run to retry."
                    Remove-Item $tmp -ErrorAction SilentlyContinue
                    continue
                }
                Remove-Item $tmp -ErrorAction SilentlyContinue

                # Add needs-attention to both the PR and the issue.
                $prNumber = ($prUrl -split '/')[-1]
                if ($prNumber -match '^\d+$') {
                    & $GH pr edit $prNumber --repo $RepoSlug --add-label $Labels.NeedsAttention
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning "[dispatch-recovery] Issue #${n}: could not add '$($Labels.NeedsAttention)' to PR #$prNumber (exit $LASTEXITCODE)."
                    }
                }
                & $GH issue edit $n --repo $RepoSlug --add-label $Labels.NeedsAttention
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "[dispatch-recovery] Issue #${n}: could not add '$($Labels.NeedsAttention)' to the issue (exit $LASTEXITCODE)."
                }
            }
            'unclaim' {
                # No commits: silently unclaim so the next dispatch run can re-dispatch.
                # Removing in-progress here is dispatcher-owned cleanup (this runs only from
                # within the dispatcher loop, DISPATCH.md Sec 1c) -- not a cross-loop label write.
                Write-Host "[dispatch-recovery] Issue #${n}: no commits; unclaiming for re-dispatch."
                & $GH issue edit $n --repo $RepoSlug --remove-label $Labels.InProgress
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "[dispatch-recovery] Issue #${n}: could not remove '$($Labels.InProgress)' (exit $LASTEXITCODE)."
                }
            }
        }

        # Remove the worktree (branch stays on remote if it was pushed above) and the lock.
        if ($wt -and (Test-Path $wt)) {
            git -C $RepoRoot worktree remove $wt
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "[dispatch-recovery] Issue #${n}: worktree removal failed (exit $LASTEXITCODE); manual cleanup needed: $wt"
            }
        }
        Remove-Item $lf.FullName -ErrorAction SilentlyContinue
        Write-Host "[dispatch-recovery] Issue #${n}: recovery complete."
    }
}
