# common.Tests.ps1 - Pester 5 unit tests for common.ps1 pure-logic functions.
#
# These tests use fixture injection (-Issues / -OpenPRs / PR detail objects) so
# they never call gh, git, or require Windows paths. They run on the Linux CI
# runner (ubuntu-latest with pwsh) as the `pester` job in ci.yml.

BeforeAll {
    # Point the config loader at a committed fixture repo so the load succeeds on CI.
    $env:AGENT_OPS_REPO = (Resolve-Path "$PSScriptRoot/fixtures/dnd").Path
    . "$PSScriptRoot/../scripts/common.ps1"
    # $StateDir (.claude/agent-state) is gitignored and won't exist on CI runners.
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }

    # Fixture helpers — defined in BeforeAll so they are available to all It blocks.
    function New-FakeIssue([int]$Number, [string[]]$Labels, [string]$Body = '') {
        [PSCustomObject]@{
            number = $Number
            title  = "Issue $Number"
            labels = @($Labels | ForEach-Object { [PSCustomObject]@{ name = $_ } })
            body   = $Body
        }
    }

    function New-FakePR([int]$Number, [string]$Branch, [string]$Body = '', [string[]]$PRLabels = @()) {
        [PSCustomObject]@{
            number      = $Number
            headRefName = $Branch
            labels      = @($PRLabels | ForEach-Object { [PSCustomObject]@{ name = $_ } })
            body        = $Body
        }
    }

    function New-FakePRDetail([string]$MergeState, [string[]]$CheckConclusions, [string]$ReviewDecision, $Comments) {
        [PSCustomObject]@{
            number            = 1
            headRefName       = 'claude/agent/issue-1'
            mergeStateStatus  = $MergeState
            statusCheckRollup = @($CheckConclusions | ForEach-Object { [PSCustomObject]@{ conclusion = $_ } })
            reviewDecision    = $ReviewDecision
            comments          = @($Comments)
        }
    }

    function New-FakeComment([string]$Body, [string]$CreatedAt) {
        [PSCustomObject]@{ body = $Body; createdAt = $CreatedAt }
    }
}

# ---------------------------------------------------------------------------
# Get-PriorityRank
# ---------------------------------------------------------------------------

Describe 'Get-PriorityRank' {
    It 'returns 0 for priority: high' {
        Get-PriorityRank (New-FakeIssue 1 @('priority: high')) | Should -Be 0
    }
    It 'returns 1 for priority: medium' {
        Get-PriorityRank (New-FakeIssue 1 @('priority: medium')) | Should -Be 1
    }
    It 'returns 2 for priority: low' {
        Get-PriorityRank (New-FakeIssue 1 @('priority: low')) | Should -Be 2
    }
    It 'returns 3 when no priority label' {
        Get-PriorityRank (New-FakeIssue 1 @('ready')) | Should -Be 3
    }
}

# ---------------------------------------------------------------------------
# Get-LinkedPRForIssue
# ---------------------------------------------------------------------------

Describe 'Get-LinkedPRForIssue' {
    It 'finds PR by exact head branch name' {
        $prs = @(New-FakePR 10 'claude/agent/issue-42')
        Get-LinkedPRForIssue -IssueNumber 42 -OpenPRs $prs | Should -Not -BeNullOrEmpty
    }
    It 'finds PR by body "closes #N" (case-insensitive)' {
        $prs = @(New-FakePR 10 'other' 'closes #42')
        Get-LinkedPRForIssue -IssueNumber 42 -OpenPRs $prs | Should -Not -BeNullOrEmpty
    }
    It 'finds PR by body "Fixes #N"' {
        $prs = @(New-FakePR 10 'other' 'Fixes #42')
        Get-LinkedPRForIssue -IssueNumber 42 -OpenPRs $prs | Should -Not -BeNullOrEmpty
    }
    It 'finds PR by body "Resolves #N"' {
        $prs = @(New-FakePR 10 'other' 'Resolves #42')
        Get-LinkedPRForIssue -IssueNumber 42 -OpenPRs $prs | Should -Not -BeNullOrEmpty
    }
    It 'returns null when no linked PR' {
        $prs = @(New-FakePR 10 'claude/agent/issue-99' 'Closes #99')
        Get-LinkedPRForIssue -IssueNumber 42 -OpenPRs $prs | Should -BeNullOrEmpty
    }
    It 'does not match a partial issue number (#420 is not #42)' {
        $prs = @(New-FakePR 10 'other' 'Closes #420')
        Get-LinkedPRForIssue -IssueNumber 42 -OpenPRs $prs | Should -BeNullOrEmpty
    }
    It 'returns null when OpenPRs is empty' {
        Get-LinkedPRForIssue -IssueNumber 42 -OpenPRs @() | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Get-DispatchableIssues
# ---------------------------------------------------------------------------

Describe 'Get-DispatchableIssues' {
    It 'returns empty when concurrency cap is reached' {
        $issues = @(New-FakeIssue 1 @('ready'))
        # One open agent PR -> cap=1 reached -> no slots
        $prs = @(New-FakePR 10 'claude/agent/issue-99')
        Get-DispatchableIssues -Cap 1 -Issues $issues -OpenPRs $prs | Should -BeNullOrEmpty
    }
    It 'filters out blocked issues' {
        $issues = @(New-FakeIssue 1 @('ready', 'blocked'))
        Get-DispatchableIssues -Cap 1 -Issues $issues -OpenPRs @() | Should -BeNullOrEmpty
    }
    It 'filters out in-progress issues' {
        $issues = @(New-FakeIssue 1 @('ready', 'in-progress'))
        Get-DispatchableIssues -Cap 1 -Issues $issues -OpenPRs @() | Should -BeNullOrEmpty
    }
    It 'filters out meta issues' {
        $issues = @(New-FakeIssue 1 @('ready', 'meta'))
        Get-DispatchableIssues -Cap 1 -Issues $issues -OpenPRs @() | Should -BeNullOrEmpty
    }
    It 'filters out help wanted issues' {
        $issues = @(New-FakeIssue 1 @('ready', 'help wanted'))
        Get-DispatchableIssues -Cap 1 -Issues $issues -OpenPRs @() | Should -BeNullOrEmpty
    }
    It 'filters out issues that already have a linked open PR' {
        $issues = @(New-FakeIssue 1 @('ready'))
        $prs    = @(New-FakePR 10 'claude/agent/issue-1')
        Get-DispatchableIssues -Cap 2 -Issues $issues -OpenPRs $prs | Should -BeNullOrEmpty
    }
    It 'returns a dispatchable issue when all criteria pass' {
        $issues = @(New-FakeIssue 5 @('ready'))
        $result = Get-DispatchableIssues -Cap 1 -Issues $issues -OpenPRs @()
        $result | Should -Not -BeNullOrEmpty
        $result[0].number | Should -Be 5
    }
    It 'sorts high > medium > no-priority, then by number ascending' {
        # Each issue declares a distinct file so the independence filter lets all three through.
        $issues = @(
            New-FakeIssue 3 @('ready')                   "## Relevant files`n- src/c.ts"
            New-FakeIssue 1 @('ready', 'priority: high') "## Relevant files`n- src/a.ts"
            New-FakeIssue 2 @('ready', 'priority: medium') "## Relevant files`n- src/b.ts"
        )
        $result = @(Get-DispatchableIssues -Cap 5 -Issues $issues -OpenPRs @())
        $result[0].number | Should -Be 1
        $result[1].number | Should -Be 2
        $result[2].number | Should -Be 3
    }
    It 'returns at most $Cap issues (less open agent PRs)' {
        $issues = @(1..5 | ForEach-Object { New-FakeIssue $_ @('ready') })
        $result = Get-DispatchableIssues -Cap 2 -Issues $issues -OpenPRs @()
        $result.Count | Should -BeLessOrEqual 2
    }
    It 'independence filter: defers second issue when both declare same file' {
        $body = "## Relevant files`n- src/foo.ts"
        $issues = @(
            New-FakeIssue 1 @('ready') $body
            New-FakeIssue 2 @('ready') $body
        )
        # @() ensures consistent array semantics (PS unwraps single-element function returns)
        $result = @(Get-DispatchableIssues -Cap 2 -Issues $issues -OpenPRs @())
        $result.Count | Should -Be 1
        $result[0].number | Should -Be 1
    }
    It 'independence filter: includes both issues when file sets are disjoint' {
        $body1 = "## Relevant files`n- src/foo.ts"
        $body2 = "## Relevant files`n- src/bar.ts"
        $issues = @(
            New-FakeIssue 1 @('ready') $body1
            New-FakeIssue 2 @('ready') $body2
        )
        $result = Get-DispatchableIssues -Cap 2 -Issues $issues -OpenPRs @()
        $result.Count | Should -Be 2
    }
}

# ---------------------------------------------------------------------------
# Get-PRNeedsAttention
# ---------------------------------------------------------------------------

Describe 'Get-PRNeedsAttention' {
    It 'returns true when mergeStateStatus is BEHIND' {
        Get-PRNeedsAttention (New-FakePRDetail 'BEHIND' @() '' @()) | Should -Be $true
    }
    It 'returns true when mergeStateStatus is DIRTY' {
        Get-PRNeedsAttention (New-FakePRDetail 'DIRTY' @() '' @()) | Should -Be $true
    }
    It 'returns true when mergeStateStatus is UNSTABLE' {
        Get-PRNeedsAttention (New-FakePRDetail 'UNSTABLE' @() '' @()) | Should -Be $true
    }
    It 'returns true when a check concluded FAILURE' {
        Get-PRNeedsAttention (New-FakePRDetail 'CLEAN' @('FAILURE') '' @()) | Should -Be $true
    }
    It 'returns true when a check concluded TIMED_OUT' {
        Get-PRNeedsAttention (New-FakePRDetail 'CLEAN' @('TIMED_OUT') '' @()) | Should -Be $true
    }
    It 'returns true when reviewDecision is CHANGES_REQUESTED' {
        Get-PRNeedsAttention (New-FakePRDetail 'CLEAN' @() 'CHANGES_REQUESTED' @()) | Should -Be $true
    }
    It 'returns true when review comment exists with no reply' {
        $rev = New-FakeComment '[Reviewing Agent] finding' '2024-01-01T10:00:00Z'
        Get-PRNeedsAttention (New-FakePRDetail 'CLEAN' @() '' @($rev)) | Should -Be $true
    }
    It 'returns true when review comment is newer than the latest implementer reply' {
        $rev  = New-FakeComment '[Reviewing Agent] finding' '2024-01-01T12:00:00Z'
        $impl = New-FakeComment '[Implementing Agent] addressed' '2024-01-01T11:00:00Z'
        Get-PRNeedsAttention (New-FakePRDetail 'CLEAN' @() '' @($rev, $impl)) | Should -Be $true
    }
    It 'returns false when implementer reply is newer than review comment' {
        $rev  = New-FakeComment '[Reviewing Agent] finding' '2024-01-01T10:00:00Z'
        $impl = New-FakeComment '[Implementing Agent] addressed' '2024-01-01T12:00:00Z'
        Get-PRNeedsAttention (New-FakePRDetail 'CLEAN' @() '' @($rev, $impl)) | Should -Be $false
    }
    It 'returns false when all checks pass and no review comment' {
        Get-PRNeedsAttention (New-FakePRDetail 'CLEAN' @('SUCCESS') '' @()) | Should -Be $false
    }
    It 'returns false for a fully clean PR (no bad state, no review, no failing checks)' {
        Get-PRNeedsAttention (New-FakePRDetail 'CLEAN' @('SUCCESS') 'APPROVED' @()) | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# Get-PRsNeedingAttention
# ---------------------------------------------------------------------------

Describe 'Get-PRsNeedingAttention' {
    It 'excludes PRs bearing the needs-attention label from the result' {
        # PR #2 is on a valid agent branch but carries the needs-attention label.
        # The label filter must eliminate it before any gh pr view call is made,
        # so the returned array must not contain PR #2.
        $labelledPR = New-FakePR 2 'claude/agent/issue-2' '' @($Labels.NeedsAttention)
        $result = Get-PRsNeedingAttention -PullRequests @($labelledPR)
        ($result | Where-Object { $_.number -eq 2 }) | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Test-PRBabysitEligible
# ---------------------------------------------------------------------------

Describe 'Test-PRBabysitEligible' {
    It 'is eligible on a branch-prefix match alone' {
        $pr = New-FakePR 1 'claude/agent/issue-1'
        Test-PRBabysitEligible -PR $pr | Should -Be $true
    }
    It 'is eligible on the opt-in babysit label alone, even off the agent branch prefix' {
        $pr = New-FakePR 3 'docs/some-interactive-branch' '' @($Labels.Babysit)
        Test-PRBabysitEligible -PR $pr | Should -Be $true
    }
    It 'is not eligible with neither the branch prefix nor the babysit label' {
        $pr = New-FakePR 4 'docs/some-interactive-branch'
        Test-PRBabysitEligible -PR $pr | Should -Be $false
    }
    It 'needs-attention overrides a branch-prefix match' {
        $pr = New-FakePR 5 'claude/agent/issue-5' '' @($Labels.NeedsAttention)
        Test-PRBabysitEligible -PR $pr | Should -Be $false
    }
    It 'needs-attention overrides an opt-in babysit label match' {
        $pr = New-FakePR 6 'docs/some-interactive-branch' '' @($Labels.Babysit, $Labels.NeedsAttention)
        Test-PRBabysitEligible -PR $pr | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# Backoff functions (Test-LoopBackoff / Update-LoopBackoff / Clear-LoopBackoff)
# ---------------------------------------------------------------------------

Describe 'Backoff functions' {
    # Uses the real $StateDir (created above if missing). AfterEach cleans up the
    # test's backoff file so each It block starts with no pre-existing state.
    AfterEach {
        Remove-Item (Join-Path $StateDir 'pester-test.backoff') -ErrorAction SilentlyContinue
    }
    It 'Test-LoopBackoff returns false when no backoff file exists' {
        Test-LoopBackoff 'pester-test' | Should -Be $false
    }
    It 'Update-LoopBackoff creates a backoff and Test-LoopBackoff returns true' {
        Update-LoopBackoff 'pester-test' | Out-Null
        Test-LoopBackoff 'pester-test' | Should -Be $true
    }
    It 'Clear-LoopBackoff removes the backoff and Test-LoopBackoff returns false' {
        Update-LoopBackoff 'pester-test' | Out-Null
        Clear-LoopBackoff 'pester-test'
        Test-LoopBackoff 'pester-test' | Should -Be $false
    }
    It 'Update-LoopBackoff increments level on repeated calls' {
        $r1 = Update-LoopBackoff 'pester-test'
        $r2 = Update-LoopBackoff 'pester-test'
        $r2.level | Should -BeGreaterThan $r1.level
    }
}

# ---------------------------------------------------------------------------
# Send-AgentComment header prepend
# ---------------------------------------------------------------------------

# Logic-extraction test: exercises the header-prepend decision inline rather than calling Send-AgentComment
# (calling the real function would require mocking $GH to avoid hitting GitHub)
Describe 'Send-AgentComment header prepend' {
    It 'prepends role header when body has none' {
        # We can't easily mock gh, so test the file content directly:
        # Manually invoke the header-prepend logic from common.ps1
        $role = 'Implementing'
        $body = 'some content'
        $header = $RoleHeaders[$role]
        $expected = "$header`n`n$body"
        $alreadyHasHeader = $RoleHeaders.Values | Where-Object { $body.TrimStart().StartsWith($_) }
        $result = if (-not $alreadyHasHeader) { "$header`n`n$body" } else { $body }
        $result | Should -Be $expected
    }
    It 'does not double-prepend if body already starts with header' {
        $role = 'Implementing'
        $header = $RoleHeaders[$role]
        $body = "$header`n`nalready has it"
        $alreadyHasHeader = $RoleHeaders.Values | Where-Object { $body.TrimStart().StartsWith($_) }
        $result = if (-not $alreadyHasHeader) { "$header`n`n$body" } else { $body }
        $result | Should -Be $body
    }
}

# ---------------------------------------------------------------------------
# New-BackoffMinutes
# ---------------------------------------------------------------------------

Describe 'New-BackoffMinutes' {
    It 'level 1 -> 15 min' { New-BackoffMinutes 1 | Should -Be 15 }
    It 'level 2 -> 30 min' { New-BackoffMinutes 2 | Should -Be 30 }
    It 'level 3 -> 60 min' { New-BackoffMinutes 3 | Should -Be 60 }
    It 'level 4 -> 120 min' { New-BackoffMinutes 4 | Should -Be 120 }
    It 'level 5 -> 240 min (cap)' { New-BackoffMinutes 5 | Should -Be 240 }
    It 'level 6 -> capped at 240 min' { New-BackoffMinutes 6 | Should -Be 240 }
    It 'level 0 -> treated as level 1 (15 min)' { New-BackoffMinutes 0 | Should -Be 15 }
}

# ---------------------------------------------------------------------------
# Get-IssueFiles
# ---------------------------------------------------------------------------

Describe 'Get-IssueFiles' {
    It 'extracts file paths from a Relevant files section' {
        $body = "## Relevant files`n- src/foo.ts`n- src/bar.ts`n## Other section"
        $files = Get-IssueFiles (New-FakeIssue 1 @() $body)
        $files | Should -Contain 'src/foo.ts'
        $files | Should -Contain 'src/bar.ts'
    }
    It 'extracts from a Scope section' {
        $body = "## Scope`n- backend/main.py`n"
        $files = Get-IssueFiles (New-FakeIssue 1 @() $body)
        $files | Should -Contain 'backend/main.py'
    }
    It 'returns empty when no Relevant files or Scope section' {
        $files = Get-IssueFiles (New-FakeIssue 1 @() 'Just a description')
        $files | Should -BeNullOrEmpty
    }
    It 'returns empty when body is blank' {
        $files = Get-IssueFiles (New-FakeIssue 1 @() '')
        $files | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Failure notifications
# ---------------------------------------------------------------------------

Describe 'Send-WindowsToast' {
    It 'does not throw on any platform (no-ops when not on Windows)' {
        { Send-WindowsToast -Title 'agent-ops: test' -Message 'unit test message' } | Should -Not -Throw
    }
}

Describe 'Send-ClaudePhonePush' {
    It 'does not throw and no-ops (never spawns a job) when the claude command is unavailable' {
        # Also mocks Start-Job and asserts it's never called - a truthy or unmocked
        # Get-Command would let this fall through to Start-Job, so a Times 0 failure
        # here would mean the Get-Command mock isn't actually being honored (e.g. on
        # a machine where claude genuinely is on PATH, this is what proves the mock
        # is intercepting the dot-sourced function's call rather than coincidentally
        # matching real command-not-found behavior on CI).
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'claude' }
        Mock Start-Job {}
        { Send-ClaudePhonePush -Message 'unit test message' } | Should -Not -Throw
        Should -Invoke Get-Command -Times 1 -Exactly -ParameterFilter { $Name -eq 'claude' }
        Should -Invoke Start-Job -Times 0 -Exactly
    }
}

Describe 'Send-LoopFailureNotification' {
    BeforeEach {
        Mock Send-WindowsToast {}
        Mock Send-ClaudePhonePush {}
    }
    It 'fires both channels with a loop- and repo-scoped title' {
        # Asserts against the fixture's known repoSlug (bendboaz/dnd-session-assistant), not
        # $RepoSlug itself - interpolating the same variable into its own filter would pass
        # trivially even if $RepoSlug were empty (`*$RepoSlug*` becomes `**`, matching anything).
        Send-LoopFailureNotification -Loop 'triage' -Detail 'Not logged in - Please run /login'
        Should -Invoke Send-WindowsToast -Times 1 -Exactly -ParameterFilter {
            $Title -like '*triage*' -and $Title -like '*bendboaz/dnd-session-assistant*' -and $Message -like '*Not logged in*'
        }
        Should -Invoke Send-ClaudePhonePush -Times 1 -Exactly -ParameterFilter {
            $Message -like '*triage*' -and $Message -like '*Not logged in*'
        }
    }
    It 'clips an overlong detail before handing it to either channel' {
        $longDetail = 'x' * 300
        Send-LoopFailureNotification -Loop 'dispatch' -Detail $longDetail
        # 140 chars + '...' (3) = 143 exactly - a tight bound so a regression that
        # widens the clip (e.g. to 144) would actually fail this assertion.
        Should -Invoke Send-WindowsToast -Times 1 -Exactly -ParameterFilter { $Message.Length -le 143 }
        # A long detail must still reach the phone-push channel, not just the toast -
        # the exact clip length for that channel is covered separately below.
        Should -Invoke Send-ClaudePhonePush -Times 1 -Exactly
    }
    It 'clips the combined phone-push message separately, since title + detail can exceed the toast clip alone' {
        $longDetail = 'x' * 300
        Send-LoopFailureNotification -Loop 'dispatch' -Detail $longDetail
        # PushNotification's own contract is ~200 chars; title + separator + the
        # 140-char detail cap (143 once '...' is appended) can exceed that, so this
        # must be clipped tighter still.
        Should -Invoke Send-ClaudePhonePush -Times 1 -Exactly -ParameterFilter { $Message.Length -le 190 }
    }
}

# ---------------------------------------------------------------------------
# Lock files: Set-AgentLock / Get-AgentLock / Remove-AgentLock / Get-AgentLockFiles
# (extended schema: worktreePath + branch, added for dead-agent recovery)
# ---------------------------------------------------------------------------

Describe 'Set-AgentLock / Get-AgentLock / Remove-AgentLock' {
    AfterEach {
        Remove-AgentLock -Loop 'pester-locktest' -IssueNumber 999
    }
    It 'round-trips issueNumber, sessionId, worktreePath, and branch through the lock file' {
        Set-AgentLock -Loop 'pester-locktest' -IssueNumber 999 -SessionId 'sess-1' `
            -WorktreePath 'D:\wt\issue-999' -Branch 'claude/agent/issue-999'

        $lf = Get-AgentLockFiles 'pester-locktest' | Where-Object { $_.Name -eq 'pester-locktest-lock-999.json' }
        $lf | Should -Not -BeNullOrEmpty

        $lock = Get-AgentLock $lf.FullName
        $lock.issueNumber  | Should -Be 999
        $lock.sessionId    | Should -Be 'sess-1'
        $lock.worktreePath | Should -Be 'D:\wt\issue-999'
        $lock.branch       | Should -Be 'claude/agent/issue-999'
        $lock.ageMins      | Should -BeLessOrEqual 1
    }
    It 'Get-AgentLock returns $null for an unreadable/corrupt lock file' {
        $path = Join-Path $StateDir 'pester-locktest-lock-corrupt.json'
        Set-Content $path 'not valid json {{{'
        try {
            Get-AgentLock $path | Should -BeNullOrEmpty
        } finally {
            Remove-Item $path -ErrorAction SilentlyContinue
        }
    }
    It 'Remove-AgentLock deletes the lock file' {
        Set-AgentLock -Loop 'pester-locktest' -IssueNumber 999 -SessionId 'sess-1' `
            -WorktreePath 'D:\wt\issue-999' -Branch 'claude/agent/issue-999'
        Remove-AgentLock -Loop 'pester-locktest' -IssueNumber 999
        (Get-AgentLockFiles 'pester-locktest' | Where-Object { $_.Name -eq 'pester-locktest-lock-999.json' }) |
            Should -BeNullOrEmpty
    }
    It 'Remove-AgentLock on a non-existent lock is a silent no-op' {
        { Remove-AgentLock -Loop 'pester-locktest' -IssueNumber 12345 } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# Test-LockStillAlive (pure)
# ---------------------------------------------------------------------------

Describe 'Test-LockStillAlive' {
    It 'alive + fresh lock -> still alive' {
        Test-LockStillAlive -Alive $true -AgeMinutes 10 | Should -Be $true
    }
    It 'alive + lock at exactly 2h -> hard TTL overrides liveness' {
        Test-LockStillAlive -Alive $true -AgeMinutes 120 | Should -Be $false
    }
    It 'alive + lock older than 2h -> hard TTL overrides liveness' {
        Test-LockStillAlive -Alive $true -AgeMinutes 150 | Should -Be $false
    }
    It 'dead session + fresh lock -> not alive' {
        Test-LockStillAlive -Alive $false -AgeMinutes 5 | Should -Be $false
    }
    It 'dead session + old lock -> not alive' {
        Test-LockStillAlive -Alive $false -AgeMinutes 200 | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# Get-LockRecoveryAction (pure)
# ---------------------------------------------------------------------------

Describe 'Get-LockRecoveryAction' {
    It 'an existing open PR wins even when the branch has commits (clear lock only)' {
        Get-LockRecoveryAction -HasExistingPR $true -HasCommits $true | Should -Be 'clear-lock-only'
    }
    It 'an existing open PR wins even when the branch has no commits (clear lock only)' {
        Get-LockRecoveryAction -HasExistingPR $true -HasCommits $false | Should -Be 'clear-lock-only'
    }
    It 'no existing PR + commits -> salvage' {
        Get-LockRecoveryAction -HasExistingPR $false -HasCommits $true | Should -Be 'salvage'
    }
    It 'no existing PR + no commits -> unclaim' {
        Get-LockRecoveryAction -HasExistingPR $false -HasCommits $false | Should -Be 'unclaim'
    }
}

# ---------------------------------------------------------------------------
# Test-SessionActive / Get-CurrentSessionId
# (filesystem-based, like the Backoff functions tests above -- real files under a
# temp TranscriptDir, script-scope $TranscriptDir saved/restored per test)
# ---------------------------------------------------------------------------

Describe 'Test-SessionActive' {
    BeforeAll {
        $script:sessionDir = Join-Path $StateDir 'pester-transcripts'
        New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
    }
    AfterAll {
        Remove-Item $sessionDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'returns false when SessionId is empty' {
        Test-SessionActive '' | Should -Be $false
    }
    It 'returns false when TranscriptDir is not configured' {
        $save = $TranscriptDir
        $TranscriptDir = $null
        try { Test-SessionActive 'some-session' | Should -Be $false }
        finally { $TranscriptDir = $save }
    }
    It 'returns false when the transcript file does not exist' {
        $save = $TranscriptDir
        $TranscriptDir = $sessionDir
        try { Test-SessionActive 'missing-session' | Should -Be $false }
        finally { $TranscriptDir = $save }
    }
    It 'returns true when the transcript was modified within the last 15 minutes' {
        $save = $TranscriptDir
        $TranscriptDir = $sessionDir
        $f = Join-Path $sessionDir 'fresh-session.jsonl'
        Set-Content $f 'x'
        (Get-Item $f).LastWriteTime = Get-Date
        try { Test-SessionActive 'fresh-session' | Should -Be $true }
        finally { $TranscriptDir = $save; Remove-Item $f -ErrorAction SilentlyContinue }
    }
    It 'returns false when the transcript is older than 15 minutes' {
        $save = $TranscriptDir
        $TranscriptDir = $sessionDir
        $f = Join-Path $sessionDir 'stale-session.jsonl'
        Set-Content $f 'x'
        (Get-Item $f).LastWriteTime = (Get-Date).AddMinutes(-30)
        try { Test-SessionActive 'stale-session' | Should -Be $false }
        finally { $TranscriptDir = $save; Remove-Item $f -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-CurrentSessionId' {
    BeforeAll {
        $script:curSessDir = Join-Path $StateDir 'pester-cursession'
        New-Item -ItemType Directory -Force -Path $curSessDir | Out-Null
    }
    AfterAll {
        Remove-Item $curSessDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'returns $null when TranscriptDir is not configured' {
        $save = $TranscriptDir
        $TranscriptDir = $null
        try { Get-CurrentSessionId | Should -BeNullOrEmpty }
        finally { $TranscriptDir = $save }
    }
    It 'returns $null when the directory has no transcripts' {
        $save = $TranscriptDir
        $TranscriptDir = $curSessDir
        try { Get-CurrentSessionId | Should -BeNullOrEmpty }
        finally { $TranscriptDir = $save }
    }
    It 'returns the filename stem of the most recently modified transcript' {
        $save = $TranscriptDir
        $TranscriptDir = $curSessDir
        $older = Join-Path $curSessDir 'older-session.jsonl'
        $newer = Join-Path $curSessDir 'newer-session.jsonl'
        Set-Content $older 'x'; (Get-Item $older).LastWriteTime = (Get-Date).AddMinutes(-10)
        Set-Content $newer 'x'; (Get-Item $newer).LastWriteTime = Get-Date
        try { Get-CurrentSessionId | Should -Be 'newer-session' }
        finally {
            $TranscriptDir = $save
            Remove-Item $older, $newer -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Invoke-DispatchRecovery
# (the salvage branch's full gh/git chain -- push + pr create + label + worktree
# remove -- is left to manual verification, see the PR description; the switch
# dispatch itself and the two non-salvage actions are covered here with a mocked
# gh. The pure Get-LockRecoveryAction / Test-LockStillAlive tests above cover the
# classifier logic feeding the switch.)
# ---------------------------------------------------------------------------

Describe 'Invoke-DispatchRecovery' {
    It 'is a no-op (no gh/git calls, no throw) when there are no lock files' {
        { Invoke-DispatchRecovery -LockFiles @() } | Should -Not -Throw
    }
    It 'removes a corrupt lock file without calling gh/git' {
        $path = Join-Path $StateDir 'pester-recovery-corrupt.json'
        Set-Content $path 'not valid json {{{'
        $lf = Get-Item $path
        try {
            { Invoke-DispatchRecovery -LockFiles @($lf) } | Should -Not -Throw
            Test-Path $path | Should -Be $false
        } finally {
            Remove-Item $path -ErrorAction SilentlyContinue
        }
    }
    It 'leaves an alive, fresh lock in place and never reaches a gh/git call' {
        $save = $TranscriptDir
        $sessDir = Join-Path $StateDir 'pester-recovery-transcripts'
        New-Item -ItemType Directory -Force -Path $sessDir | Out-Null
        $TranscriptDir = $sessDir
        $transcript = Join-Path $sessDir 'alive-session.jsonl'
        Set-Content $transcript 'x'
        (Get-Item $transcript).LastWriteTime = Get-Date

        Set-AgentLock -Loop 'pester-recovery' -IssueNumber 4242 -SessionId 'alive-session' `
            -WorktreePath 'D:\nonexistent\issue-4242' -Branch 'claude/agent/issue-4242'
        $lf = Get-AgentLockFiles 'pester-recovery' | Where-Object { $_.Name -eq 'pester-recovery-lock-4242.json' }

        try {
            { Invoke-DispatchRecovery -LockFiles @($lf) } | Should -Not -Throw
            # Still alive -> the lock must survive the scan (recovery never got past the
            # skip-alive short-circuit, so it never reached a gh/git call).
            Test-Path $lf.FullName | Should -Be $true
        } finally {
            $TranscriptDir = $save
            Remove-AgentLock -Loop 'pester-recovery' -IssueNumber 4242
            Remove-Item $sessDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # The next two exercise the switch dispatch for a dead lock (no transcript -> not
    # alive -> Test-LockStillAlive $false). $GH is pointed at the command name 'gh' so
    # Pester's mock intercepts `& $GH ...`; the worktree path is non-existent so the
    # git-log / worktree-remove calls are never reached (the classifier decides from
    # the mocked `gh pr list` result alone).
    Context 'switch dispatch for a dead lock (mocked gh)' {
        BeforeEach {
            $script:ghSaved = $GH
            $GH = 'gh'
            Mock git {}   # defensive: nothing in these paths should reach git
            # Catch-all so any unexpected `gh` call is intercepted (not passed to the real
            # gh) and counted -- this is what makes the `Should -Not -Invoke` assertions
            # below meaningful. Per-path `Mock gh -ParameterFilter` overrides it.
            Mock gh { $global:LASTEXITCODE = 0 }
        }
        AfterEach {
            $GH = $ghSaved
            Remove-AgentLock -Loop 'pester-recovery' -IssueNumber 4343
            Remove-AgentLock -Loop 'pester-recovery' -IssueNumber 4344
        }

        It "clear-lock-only: an existing open PR just removes the stale lock" {
            Mock gh { $global:LASTEXITCODE = 0; '[{"number":77}]' } -ParameterFilter { $args -contains 'list' }
            Set-AgentLock -Loop 'pester-recovery' -IssueNumber 4343 -SessionId 'dead-sess' `
                -WorktreePath 'D:\nonexistent\issue-4343' -Branch 'claude/agent/issue-4343'
            $lf = Get-AgentLockFiles 'pester-recovery' | Where-Object { $_.Name -eq 'pester-recovery-lock-4343.json' }

            { Invoke-DispatchRecovery -LockFiles @($lf) } | Should -Not -Throw

            Test-Path $lf.FullName | Should -Be $false
            Should -Invoke gh -ParameterFilter { $args -contains 'list' }
            Should -Not -Invoke gh -ParameterFilter { $args -contains 'edit' }
        }

        It "unclaim: no PR + no commits removes in-progress and the lock" {
            $Labels.InProgress | Should -Not -BeNullOrEmpty   # precondition: the -ParameterFilter below is only meaningful with a real label
            Mock gh { $global:LASTEXITCODE = 0; '[]' } -ParameterFilter { $args -contains 'list' }
            Mock gh { $global:LASTEXITCODE = 0 } -ParameterFilter { $args -contains 'edit' }
            Set-AgentLock -Loop 'pester-recovery' -IssueNumber 4344 -SessionId 'dead-sess' `
                -WorktreePath 'D:\nonexistent\issue-4344' -Branch 'claude/agent/issue-4344'
            $lf = Get-AgentLockFiles 'pester-recovery' | Where-Object { $_.Name -eq 'pester-recovery-lock-4344.json' }

            { Invoke-DispatchRecovery -LockFiles @($lf) } | Should -Not -Throw

            Test-Path $lf.FullName | Should -Be $false
            Should -Invoke gh -ParameterFilter {
                ($args -contains 'edit') -and ($args -contains '--remove-label') -and ($args -contains $Labels.InProgress)
            }
        }
    }
}
