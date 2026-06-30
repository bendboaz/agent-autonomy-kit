---
name: triage-backlog
description: Groom a GitHub backlog — assess open issues (comment-aware), refresh a single triage-report issue (ready candidates, priorities, blocked/waiting/dup/stale, meta), and flesh out `help wanted` issues (expand bodies + analysis comments, split into children when asked). Never applies gating labels, never closes issues. Use to triage the backlog, propose ready issues, or run the nightly grooming pass. Reads .agent-ops/config.json. Windows/PowerShell.
---

## Scope

Operates on **the current repo** (identity in `.agent-ops/config.json`). Read-mostly, with
issue-write permission for its own triage-report and for `help wanted` grooming.

## Identity & token

Acts under the App in `.agent-ops/config.json`. **Launched by `run-triage.ps1`** → `GH_TOKEN` is minted;
verify `& $GH auth status` shows the App bot. **Manual** → from the repo root set `$env:AGENT_OPS_REPO`,
dot-source the plugin's `scripts/common.ps1`, run `Initialize-AgentAuth`. `GH_APP_PRIVATE_KEY_PATH` must
be a user-scope env var (never set the `.pem` path in a command).

## How to run

1. Read and follow this plugin's **`playbooks/OPERATIONS.md`** (shared contract — identity, labels,
   coordination, escalation, Windows/PowerShell gotchas) + the repo's **`.agent-ops/REPO-FACTS.md`**.
2. Read and follow this plugin's **`playbooks/TRIAGE.md`** (step-by-step procedure).

The triage date is today's date in `YYYY-MM-DD` (`$triageDate`); do not invent one.

## Guarantee — bounded

**Never** applies/removes the gating labels (`ready`, `priority:*`, `blocked`, `in-progress`,
`needs-attention`), **never** closes/reopens/restructures issues, opens no code PRs, touches no
branches. The human is the sole gate on labeling and on closing.

It **may** write: its own triage-report issue (create / in-place update); and — on **`help wanted`**
issues only — an expanded body plus a role-headed analysis comment, and new child issues when the
discussion asks for a split (parent linked and left open). Comments are authoritative: a human
"wait / hold" comment disqualifies an issue from `ready`. See TRIAGE.md.
