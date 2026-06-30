# config.Tests.ps1 - parity + validation for the config loader (agent-config.ps1).
#
# Golden master: the config-driven loader must reproduce the values the original
# hardcoded agent-config.ps1 defined for dnd-session-assistant. Plus: a malformed
# or missing config must be rejected (fail fast, not silently mis-load).

Describe 'Config loader parity (dnd fixture == original hardcoded constants)' {
    BeforeAll {
        $env:AGENT_OPS_REPO = (Resolve-Path "$PSScriptRoot/fixtures/dnd").Path
        . "$PSScriptRoot/../scripts/agent-config.ps1"
    }
    It 'repoSlug'        { $RepoSlug       | Should -Be 'bendboaz/dnd-session-assistant' }
    It 'appId'           { $AppId          | Should -Be '4070567' }
    It 'installationId'  { $InstallationId | Should -Be '140736715' }
    It 'branchPrefix'    { $BranchPrefix   | Should -Be 'claude/agent/issue-' }
    It 'defaultCap is 1 (resolves the old 1-vs-3 doc drift; config is the source of truth)' {
        $DefaultCap | Should -Be 1
    }
    It 'labels reproduce the original taxonomy' {
        $Labels.Ready          | Should -Be 'ready'
        $Labels.InProgress     | Should -Be 'in-progress'
        $Labels.Blocked        | Should -Be 'blocked'
        $Labels.NeedsAttention | Should -Be 'needs-attention'
        $Labels.HelpWanted     | Should -Be 'help wanted'
        $Labels.Meta           | Should -Be 'meta'
    }
    It 'role headers carry the [Role] tags the attention classifier greps for' {
        $RoleHeaders.Implementing | Should -Match '\[Implementing Agent\]'
        $RoleHeaders.Reviewing    | Should -Match '\[Reviewing Agent\]'
        $RoleHeaders.Human        | Should -Match '\[Human\]'
    }
    It 'role headers keep their emoji prefix (UTF-8 survived the load)' {
        # The full header is longer than the plain "**[Implementing Agent]**" text,
        # i.e. the emoji + space prefix round-tripped through Get-Content -Encoding UTF8.
        $RoleHeaders.Implementing.Length | Should -BeGreaterThan '**[Implementing Agent]**'.Length
    }
    It 'merges machine paths from config.local.json (worktreeBase)' {
        $WorktreeBase | Should -Be 'X:\wt'
    }
    It 'resolves StateDir under the repo root' {
        $StateDir | Should -Match 'agent-state'
    }
    It 'AgentOpsPath defaults to the .agent-ops convention' {
        $AgentOpsPath | Should -Be '.agent-ops'
    }
}

Describe 'Config loader validation' {
    It 'throws when a required key (repoSlug) is missing' {
        $env:AGENT_OPS_REPO = (Resolve-Path "$PSScriptRoot/fixtures/bad").Path
        { . "$PSScriptRoot/../scripts/agent-config.ps1" } | Should -Throw
    }
    It 'throws when the repo has no .agent-ops/config.json' {
        # tests/ itself has no .agent-ops dir.
        $env:AGENT_OPS_REPO = (Resolve-Path "$PSScriptRoot").Path
        { . "$PSScriptRoot/../scripts/agent-config.ps1" } | Should -Throw
    }
}
