---
name: dispatch-ready-issues
description: Turn `ready` GitHub issues into PRs under the repo's configured non-admin GitHub App (the autonomous dispatcher). Use when the user wants to dispatch ready issues, run the issue→PR loop, or clear the groomed backlog. Reads identity from .agent-ops/config.json; requires the App key env (see body). Windows/PowerShell.
---

## Scope

Operates on **the current repo** — the one this session runs in. Its identity (repo slug, App ID,
installation ID, labels, branch prefix, concurrency cap) comes from **`.agent-ops/config.json`** at the
repo root. The procedure lives in this plugin's `playbooks/`; repo-specific facts live in the repo's
`.agent-ops/REPO-FACTS.md`.

## Identity & token (KEY-ENV precondition)

Acts under the **GitHub App** in `.agent-ops/config.json` (`appId` / `installationId`) — never as the
human.

**Launched by `run-dispatch.ps1`** → `GH_TOKEN` is already minted; just verify identity:

```powershell
& $GH auth status   # must show the App bot (…[bot]), not the human
```

**Manual run (no `GH_TOKEN`)** → mint it. `GH_APP_PRIVATE_KEY_PATH` must already be a **user-scope**
environment variable (its `.pem` path triggers the sensitive-file hook — never set it in a command).
From the repo root:

```powershell
$env:AGENT_OPS_REPO = (Get-Location).Path
. "$env:AGENT_OPS_PLUGIN/scripts/common.ps1"   # the agent-ops plugin's scripts dir
Initialize-AgentAuth                            # reads appId/installationId from config + mints GH_TOKEN
& $GH auth status                               # verify the App bot
```

If neither `GH_TOKEN` nor `GH_APP_PRIVATE_KEY_PATH` is present, **stop** and ask the user to set
`GH_APP_PRIVATE_KEY_PATH` (user-scope) and relaunch. Token TTL ~10 min; re-mint on long runs with
`Update-AgentToken`.

## How to execute

1. Read this plugin's **`playbooks/OPERATIONS.md`** (the frozen shared contract — identity, labels,
   branch naming, role headers, escalation) **and** the repo's **`.agent-ops/REPO-FACTS.md`** (this
   repo's contract files, required checks, conventions). Do not contradict them.
2. Read and follow this plugin's **`playbooks/DISPATCH.md`** — the selection → claim → build → verify →
   open-PR procedure.

## Dead-agent recovery

On every run, **before** selecting new work, run the plugin's `scripts/dispatch-recovery.ps1`
(DISPATCH.md §1c) to salvage partial work or unclaim issues from interrupted prior sessions. If the
script isn't present yet, note it and continue — recovery degrades gracefully.

## Safe first action: dry run

Before any writes, run the selection in dry-run mode (DISPATCH.md) — it reads GitHub and prints the
ordered list that would be dispatched, making **zero** writes. Proceed to the full run only after the
selection looks correct.

## Hard guardrails (one line)

Never merge or approve a PR; honor the concurrency cap (`defaultCap` in config); escalate at the
boundary (ambiguity, a contract-file change, an unresolvable verification failure) — add
`needs-attention`, post an `[Implementing Agent]` comment, send a PushNotification, clear
`in-progress`, and move on.
