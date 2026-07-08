# sensitive-files-guard.Tests.ps1 - functional coverage for the sensitive-files guardrail hook's
# Grep-glob handling (Rule 4) and the .claude exemption.
#
# Named to avoid the hook's own guardrail: block-dangerous-commands.ps1 denies Edit/Write on any
# path containing "block-sensitive-files", so a test file can't carry the hook's own filename.
#
# Pipes synthetic PreToolUse JSON into the real hook and parses the structured
# hookSpecificOutput - asserting on permissionDecision AND the specific matchedReason text, not
# just output non-emptiness, so a hook crash can't be mistaken for a legitimate deny and a
# passing test proves *which* rule fired, not merely that something denied.

Describe 'block-sensitive-files: Grep glob handling (Rule 4)' {
    BeforeAll {
        $hookPath = Join-Path $PSScriptRoot '../hooks/block-sensitive-files.ps1'

        function Invoke-Guard([string]$Json) {
            $out = $Json | & $hookPath
            if ([string]::IsNullOrEmpty($out)) {
                return [PSCustomObject]@{ Deny = $false; Reason = $null }
            }
            $parsed = $out | ConvertFrom-Json
            [PSCustomObject]@{
                Deny   = ($parsed.hookSpecificOutput.permissionDecision -eq 'deny')
                Reason = $parsed.hookSpecificOutput.permissionDecisionReason
            }
        }
    }

    It 'denies a Grep glob targeting the OAuth credentials store, even with no path (fast-path via glob)' {
        $r = Invoke-Guard '{"tool_name":"Grep","tool_input":{"glob":"*.credentials.json"}}'
        $r.Deny | Should -BeTrue
        $r.Reason | Should -Match 'OAuth token store'
    }

    It 'denies a Grep glob under a .claude/ prefix targeting the credentials store (the exemption bypass)' {
        $r = Invoke-Guard '{"tool_name":"Grep","tool_input":{"glob":"x/.claude/*.credentials.json"}}'
        $r.Deny | Should -BeTrue
        $r.Reason | Should -Match 'OAuth token store'
    }

    It 'denies a Grep glob matching *password* via Rule 4, with a directory path also given' {
        $r = Invoke-Guard '{"tool_name":"Grep","tool_input":{"path":"config","glob":"*password*"}}'
        $r.Deny | Should -BeTrue
        $r.Reason | Should -Match "Grep glob targets pattern '\*password\*'"
    }

    It 'denies a Grep glob matching *secret* via Rule 4' {
        $r = Invoke-Guard '{"tool_name":"Grep","tool_input":{"path":"config","glob":"*secret*"}}'
        $r.Deny | Should -BeTrue
        $r.Reason | Should -Match "Grep glob targets pattern '\*secret\*'"
    }

    It 'still denies via the credentials fast-path when both a .claude path and a matching glob are given' {
        $r = Invoke-Guard '{"tool_name":"Grep","tool_input":{"path":".claude/foo.json","glob":"*.credentials.json"}}'
        $r.Deny | Should -BeTrue
        $r.Reason | Should -Match 'OAuth token store'
    }

    It 'allows a legitimate Grep under .claude/ with no sensitive glob' {
        (Invoke-Guard '{"tool_name":"Grep","tool_input":{"path":".claude/settings.json"}}').Deny | Should -BeFalse
    }

    It 'allows a normal Grep over source files' {
        (Invoke-Guard '{"tool_name":"Grep","tool_input":{"path":"src","glob":"*.ts"}}').Deny | Should -BeFalse
    }
}
