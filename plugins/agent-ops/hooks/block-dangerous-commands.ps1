# block-dangerous-commands.ps1
# PreToolUse deny-gate for the autonomous agent loops (dispatch / babysit / triage).
#
# Philosophy: allow broadly, DENY a curated set of dangerous / out-of-scope operations.
# It blocks the OPERATION regardless of which credential is in play, so even if a loop
# falls back to the human gh token / SSH key, it still cannot merge, change protection,
# force-push to main, delete trees, or touch the machine.
#
# Wire as a PreToolUse hook (matcher: Bash|PowerShell|CMD|Edit|Write) in the project's
# .claude/settings.local.json so it governs ONLY sessions running in this repo (the loops),
# not your global interactive sessions.
#
# Fail-open: on any unexpected error this exits 0 (allow), to avoid bricking a session.
# GitHub-side guardrails (non-admin App + branch protection) remain as the backstop.
#
# Emits the same PreToolUse "deny" JSON shape as block-sensitive-files.ps1.

try {
    $json = $input | ConvertFrom-Json
    $tool = $json.tool_name

    $isShell = $tool -in @("Bash", "PowerShell", "CMD")
    $isFile  = $tool -in @("Edit", "Write")
    if (-not ($isShell -or $isFile)) { exit 0 }

    $deny = $null

    if ($isShell) {
        $cmd = [string]$json.tool_input.command
        if (-not $cmd) { exit 0 }

        # (regex, reason) - regexes are matched case-insensitively against the whole command.
        $rules = @(
            @{ rx = 'gh\s+pr\s+merge';                                            why = 'merging PRs is forbidden (only the human merges)' },
            @{ rx = 'gh\s+pr\s+review\b[^\n]*--approve';                          why = 'approving PRs is forbidden' },
            @{ rx = 'gh\s+repo\s+(edit|delete|archive|rename)';                   why = 'repo administration is forbidden' },
            @{ rx = 'gh\s+(ruleset|secret|variable)\b';                           why = 'rulesets/secrets/variables admin is forbidden' },
            @{ rx = 'gh\s+api\b[^\n]*(--method\s*|-X\s*)(POST|PUT|PATCH|DELETE)'; why = 'write gh api calls are forbidden' },
            @{ rx = 'gh\s+api\b[^\n]*(protection|rulesets|/branches/)';           why = 'branch-protection / ruleset API is forbidden' },
            @{ rx = 'git\s+push\b[^\n]*\b(main|master)\b';                        why = 'pushing to the protected default branch is forbidden' },
            @{ rx = 'git\s+push\b[^\n]*(--force\b(?!-with-lease)|\s-f\b)';        why = 'force-push is forbidden (use --force-with-lease on a feature branch)' },
            @{ rx = 'git\s+branch\s+-D\s+(main|master)\b';                        why = 'deleting the default branch is forbidden' },
            @{ rx = 'Remove-Item\b[^\n]*-Recurse';                               why = 'recursive deletion is forbidden' },
            @{ rx = '\brm\s+-[a-zA-Z]*r';                                         why = 'recursive rm is forbidden' },
            @{ rx = '\b(rd|rmdir)\b[^\n]*/s';                                     why = 'recursive rmdir is forbidden' },
            @{ rx = '\bdel\b[^\n]*/s';                                            why = 'recursive del is forbidden' },
            @{ rx = '(Format-Volume|Format-Disk|Clear-Disk)';                     why = 'disk formatting is forbidden' },
            @{ rx = '(\bshutdown\b|Stop-Computer|Restart-Computer)';              why = 'powering off/restarting is forbidden' },
            @{ rx = 'Set-ExecutionPolicy';                                        why = 'changing execution policy is forbidden' },
            @{ rx = '(New-LocalUser|Add-LocalGroupMember|\bnet\s+user\b)';        why = 'local account changes are forbidden' },
            @{ rx = '\bnetsh\b';                                                  why = 'network configuration is forbidden' },
            @{ rx = '\breg\s+(add|delete)\b';                                     why = 'registry edits are forbidden' },
            @{ rx = '(Register-ScheduledTask|Unregister-ScheduledTask|Set-ScheduledTask|schtasks\s+/(create|delete|change))'; why = 'scheduled-task changes are forbidden' },
            @{ rx = '(Set-MpPreference|Add-MpPreference)';                        why = 'antivirus changes are forbidden' },
            @{ rx = '(Invoke-Expression|\biex\s)';                                why = 'Invoke-Expression is forbidden' },
            @{ rx = '(block-dangerous-commands|block-sensitive-files|settings\.local\.json)'; why = 'tampering with the agent guardrails is forbidden' }
        )
        foreach ($r in $rules) {
            if ($cmd -match "(?i)$($r.rx)") { $deny = $r.why; break }
        }
    }
    elseif ($isFile) {
        $fp = [string]$json.tool_input.file_path
        if (-not $fp) { $fp = [string]$json.tool_input.path }
        if (-not $fp) { exit 0 }
        $p = ($fp -replace '\\', '/').ToLower()

        $fileRules = @(
            @{ rx = '/\.github/workflows/';                             why = 'editing CI workflows is forbidden (escalate to the human)' },
            @{ rx = '(block-dangerous-commands|block-sensitive-files)'; why = 'editing the guardrail hooks is forbidden' },
            @{ rx = '/\.claude/settings(\.local)?\.json';               why = 'editing the permission allowlist is forbidden' }
        )
        # The agent-ops playbook (procedures, minter, cleanup) is ORCHESTRATOR-ONLY.
        # Dispatched loops mark themselves with AGENT_LOOP=1 (set by the run-*.ps1 wrappers);
        # they may not edit it. The interactive orchestrator (no AGENT_LOOP) is unaffected.
        if ($env:AGENT_LOOP -eq '1') {
            $fileRules += @{ rx = '/(\.agent-ops|infra/agent-ops)/'; why = 'the per-repo agent-ops config (.agent-ops/**) is orchestrator-only; escalate changes to the human' }
        }
        foreach ($r in $fileRules) {
            if ($p -match $r.rx) { $deny = $r.why; break }
        }
    }

    if ($deny) {
        @{
            hookSpecificOutput = @{
                hookEventName            = "PreToolUse"
                permissionDecision       = "deny"
                permissionDecisionReason = "BLOCKED by agent guardrail: $deny. If this is intentional, run it yourself or adjust the rule in block-dangerous-commands.ps1."
            }
        } | ConvertTo-Json -Compress
    }
    exit 0
}
catch {
    # Fail open - never break a session on a hook bug. GitHub-side guards remain.
    exit 0
}
