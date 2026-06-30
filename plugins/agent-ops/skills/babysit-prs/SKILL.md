---
name: babysit-prs
description: Keep agent-authored PRs green and mergeable — mechanical fixes only, escalate substantive issues. Use when the user wants to babysit open agent PRs, keep PRs green, or address CI/AI-review nits. Reads identity from .agent-ops/config.json; requires the App key env (see body). Windows/PowerShell.
---

## Scope

Operates on **the current repo** (identity in `.agent-ops/config.json`). Touches only open PRs whose
head branch matches the configured `branchPrefix` (e.g. `claude/agent/issue-*`) — the autonomous lane.
Never touches an interactive `claude/...` (non-agent) branch.

## Identity & token

Acts under the App in `.agent-ops/config.json`. **Launched by `run-babysit.ps1`** → `GH_TOKEN` is
already minted; verify `& $GH auth status` shows the App bot. **Manual** → from the repo root set
`$env:AGENT_OPS_REPO`, dot-source the plugin's `scripts/common.ps1`, run `Initialize-AgentAuth`.
`GH_APP_PRIVATE_KEY_PATH` must be a user-scope env var (never set the `.pem` path in a command). Do not
proceed if auth shows the human.

## Procedure

Read in full before acting:

1. This plugin's **`playbooks/OPERATIONS.md`** (shared contract) + the repo's **`.agent-ops/REPO-FACTS.md`**.
2. This plugin's **`playbooks/BABYSIT.md`** (PR selection, rebase, CI triage, AI-review nit handling,
   commit-cap, timing-race note, done-state notification). OPERATIONS.md is the authority on conflict.

## Hard guardrails (non-negotiable)

- **Scope:** only `branchPrefix` PRs. Never touch an interactive (non-agent) `claude/...` branch.
- **Mechanical fixes only.** A fix needing real logic or a product decision → escalate (`needs-attention`
  + an `[Implementing Agent]` comment + a PushNotification).
- **Commit-cap:** default 3 pushes per PR per run → hit the cap, escalate, move on.
- **Never** approve, merge, force-past a required check, edit `.github/workflows/*`, or change branch
  protection or secrets.
