# agent-autonomy-kit

A repo-agnostic, version-tracked packaging of an autonomous **GitHub agent-ops** mechanism for
[Claude Code](https://code.claude.com), extracted from the `dnd-session-assistant` project so it can
drive any repository.

It gives a repo four cooperating roles, all acting under a **non-admin GitHub App** (so they
*physically cannot merge* — the human merges a branch-protected `main`):

| Role | What it does | Cadence |
|---|---|---|
| **Dispatch** | turns `ready` issues into PRs (claim → worktree → build → verify → open PR) | scheduled |
| **Babysit** | keeps agent PRs green & mergeable (rebase, CI triage, address review nits) | scheduled |
| **Triage** | grooms the backlog (a report issue; expands `help wanted`) | nightly |
| **AI review** | conversation-aware PR review posting as `🔎 [Reviewing Agent]` | every PR sync (CI) |
| **Orchestrator** | the human's interactive supervisor (HEALTHCHECK, playbook changes) | on demand |

## How it's shipped

- **Plugin** `plugins/agent-ops/` — skills, slash commands, guardrail hooks, the PowerShell engine,
  the GitHub-App token minter, the generic playbooks, and the AI-review script.
- **Marketplace** `.claude-plugin/marketplace.json` — `claude plugin install agent-ops@boaz-agent-ops`.
- **Reusable workflow** `.github/workflows/ai-review-reusable.yml` — each repo's `ai-review.yml` is a
  thin caller.

## Using it on a repo

A consuming repo carries only a small `.agent-ops/` folder (`config.json`, gitignored
`config.local.json`, `REPO-FACTS.md`, `REVIEW-CHECKLIST.md`) plus a thin `ai-review.yml`. Loops run
locally via Windows Task Scheduler, registered with `install-tasks.ps1 -RepoRoot <repo>`. See
[`docs/ONBOARDING.md`](docs/ONBOARDING.md).

> **Precondition:** consuming repos must be **public with branch protection on `main`** — that's what
> makes the App unable to merge. See [`docs/SECURITY.md`](docs/SECURITY.md).

## Status

Under active extraction from `dnd-session-assistant` (the source of truth, currently on branch
`ops/common-helper-layer`). See the implementation plan and `docs/ARCHITECTURE.md`.

## Platform

Windows / PowerShell. `gh` CLI + Python 3.12 (for the token minter and AI reviewer).
