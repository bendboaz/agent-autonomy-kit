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
        Should -Invoke Get-Command -Times 1 -ParameterFilter { $Name -eq 'claude' }
        Should -Invoke Start-Job -Times 0
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
        Should -Invoke Send-WindowsToast -Times 1 -ParameterFilter {
            $Title -like '*triage*' -and $Title -like '*bendboaz/dnd-session-assistant*' -and $Message -like '*Not logged in*'
        }
        Should -Invoke Send-ClaudePhonePush -Times 1 -ParameterFilter {
            $Message -like '*triage*' -and $Message -like '*Not logged in*'
        }
    }
    It 'clips an overlong detail before handing it to either channel' {
        $longDetail = 'x' * 300
        Send-LoopFailureNotification -Loop 'dispatch' -Detail $longDetail
        # 140 chars + '...' (3) = 143 exactly - a tight bound so a regression that
        # widens the clip (e.g. to 144) would actually fail this assertion.
        Should -Invoke Send-WindowsToast -Times 1 -ParameterFilter { $Message.Length -le 143 }
    }
    It 'clips the combined phone-push message separately, since title + detail can exceed the toast clip alone' {
        $longDetail = 'x' * 300
        Send-LoopFailureNotification -Loop 'dispatch' -Detail $longDetail
        # PushNotification's own contract is ~200 chars; title + separator + the
        # 143-char detail clip can exceed that, so this must be clipped tighter still.
        Should -Invoke Send-ClaudePhonePush -Times 1 -ParameterFilter { $Message.Length -le 190 }
    }
}
