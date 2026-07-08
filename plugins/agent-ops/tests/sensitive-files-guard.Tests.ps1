# sensitive-files-guard.Tests.ps1 - functional coverage for the sensitive-files guardrail hook's
# Grep-glob handling (Rule 4) and the .claude exemption.
#
# Named to avoid the hook's own guardrail: block-dangerous-commands.ps1 denies Edit/Write on any
# path containing "block-sensitive-files", so a test file can't carry the hook's own filename.
#
# Added after two AI-review rounds gave conflicting diagnoses of which code path handles Grep
# globs. This file pipes synthetic PreToolUse JSON into the real hook and asserts allow/deny, so
# the question is settled by execution instead of by re-reading indentation.

Describe 'block-sensitive-files: Grep glob handling (Rule 4)' {
    BeforeAll {
        $hookPath = Join-Path $PSScriptRoot '../hooks/block-sensitive-files.ps1'

        function Invoke-Guard([string]$Json) {
            $out = $Json | & $hookPath
            -not [string]::IsNullOrEmpty($out)
        }
    }

    It 'denies a Grep glob targeting the OAuth credentials store, even with no path (fast-path via glob)' {
        Invoke-Guard '{"tool_name":"Grep","tool_input":{"glob":"*.credentials.json"}}' | Should -BeTrue
    }

    It 'denies a Grep glob under a .claude/ prefix targeting the credentials store (the exemption bypass)' {
        Invoke-Guard '{"tool_name":"Grep","tool_input":{"glob":"x/.claude/*.credentials.json"}}' | Should -BeTrue
    }

    It 'denies a Grep glob matching *password* with a directory path also given' {
        Invoke-Guard '{"tool_name":"Grep","tool_input":{"path":"config","glob":"*password*"}}' | Should -BeTrue
    }

    It 'denies a Grep glob matching *secret*' {
        Invoke-Guard '{"tool_name":"Grep","tool_input":{"path":"config","glob":"*secret*"}}' | Should -BeTrue
    }

    It 'still denies via the credentials fast-path when both a .claude path and a matching glob are given' {
        Invoke-Guard '{"tool_name":"Grep","tool_input":{"path":".claude/foo.json","glob":"*.credentials.json"}}' | Should -BeTrue
    }

    It 'allows a legitimate Grep under .claude/ with no sensitive glob' {
        Invoke-Guard '{"tool_name":"Grep","tool_input":{"path":".claude/settings.json"}}' | Should -BeFalse
    }

    It 'allows a normal Grep over source files' {
        Invoke-Guard '{"tool_name":"Grep","tool_input":{"path":"src","glob":"*.ts"}}' | Should -BeFalse
    }
}
