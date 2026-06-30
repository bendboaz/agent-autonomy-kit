# Onboarding a repo

How to put a repo under agent-ops. Windows / PowerShell.

## Preconditions (hard)

1. **The repo is PUBLIC with branch protection on `main`** (PR + ≥1 approval, no self-approve, required
   checks, `enforce_admins=false`). This is what makes the App unable to merge — see [SECURITY.md](SECURITY.md).
   On a GH plan where private repos can't have branch protection, the repo must be public.
2. **A GitHub App** (non-admin: contents + PRs + issues write, no admin/merge) is **installed on the repo**.
   You can reuse one App across repos — each repo just needs its own Installation ID.
3. The App's **private key `.pem`** lives outside any repo, at the path in the user-scope env var
   `GH_APP_PRIVATE_KEY_PATH`.
4. `ANTHROPIC_API_KEY` is added as a **repo secret** (for the AI reviewer).

## Steps

### 1. Install the plugin (once per machine)
```powershell
claude plugin marketplace add bendboaz/agent-autonomy-kit
claude plugin install agent-ops@boaz-agent-ops
# enable it for this repo (per-project, so the guardrail hook scopes to opted-in repos)
```

### 2. Add `.agent-ops/` to the repo
Copy the templates from the plugin (`plugins/agent-ops/templates/`) and fill them in:
```
<repo>/.agent-ops/
├─ config.json          # from config.example.json — repoSlug, appId, installationId, appBotLogin,
│                       #   branchPrefix, defaultCap, labels{}, roleHeaders{}, verify{}, agentOpsPath
├─ config.local.json    # from config.local.example.json — GITIGNORED machine paths (worktreeBase, venvScripts, ghPath)
├─ REPO-FACTS.md        # from REPO-FACTS.example.md — required checks, local verify, contract files, conventions
└─ REVIEW-CHECKLIST.md  # from REVIEW-CHECKLIST.example.md — the project's AI-review checklist
```
Add `**/config.local.json`, `**/agent-state/`, `*.backoff`, and `*-lock-*.json` to the repo's `.gitignore`.

### 3. Wire the AI reviewer
Copy `templates/ai-review.caller.yml` to `<repo>/.github/workflows/ai-review.yml`; set its
`paths:` filter to your source dirs. Confirm `ANTHROPIC_API_KEY` is a repo secret.

### 4. Register the loops (run in a real terminal, not via Claude)
```powershell
# From a PowerShell terminal (PS 5.1 or PS 7 both work):
.\<plugin>\scripts\install-tasks.ps1 -RepoRoot <repo root> -WhatIf   # preview
.\<plugin>\scripts\install-tasks.ps1 -RepoRoot <repo root>           # register
```
This creates `agentops-<repo>-{dispatch,babysit,triage}` scheduled tasks. Remove with
`.\<plugin>\scripts\uninstall-tasks.ps1 -RepoRoot <repo root>`.

## Verify

1. **Auth:** from the repo root, `$env:AGENT_OPS_REPO = (Get-Location).Path`, dot-source the plugin's
   `scripts/common.ps1`, run `Initialize-AgentAuth` → `gh auth status` shows the App bot, not you.
2. **Dispatch dry run:** `/dispatch-ready-issues` and follow DISPATCH.md's dry-run step — it prints the
   ordered selection with **zero** writes.
3. **AI review:** open a test PR (or `workflow_dispatch` the ai-review workflow with a PR number) → a
   `[Reviewing Agent]` comment appears.
4. **Loops:** let the scheduled tasks fire once, or run a wrapper manually:
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <plugin>\scripts\run-dispatch.ps1 -RepoRoot <repo root>`.

## Day-2

Supervise with `/orchestrate-agent-ops` (the HEALTHCHECK). Change loop *behavior* in the kit (the
plugin); change repo *facts* in the repo's `.agent-ops/**` via a PR. Never let a loop edit its own rules.
