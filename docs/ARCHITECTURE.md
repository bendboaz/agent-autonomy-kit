# Architecture

`agent-autonomy-kit` packages an autonomous GitHub agent-ops mechanism so it can drive any repo. It was
extracted from `dnd-session-assistant`, which remains the reference implementation.

## The roles

| Role | Runs | What it does |
|---|---|---|
| **Dispatch** | local scheduled task → `run-dispatch.ps1` | deterministic ready-issue selection, then `claude -p /dispatch-ready-issues` to claim → worktree → build → verify → open PR |
| **Babysit** | local scheduled task → `run-babysit.ps1` | deterministic "needs attention" check, then `claude -p /babysit-prs` to rebase / fix CI / address review nits |
| **Triage** | local scheduled task → `run-triage.ps1` | `claude -p /triage-backlog` to refresh a report issue + groom `help wanted` |
| **AI review** | GitHub Actions (per PR) | the conversation-aware reviewer posts `[Reviewing Agent]` comments |
| **Orchestrator** | interactive human session | HEALTHCHECK + playbook changes (`/orchestrate-agent-ops`) |

All four agent roles act under a **non-admin GitHub App**. Because the App is not an admin and `main` is
branch-protected, **it physically cannot merge** — the human merges. That is the core safety property
(enforced by GitHub, not by agent good behavior).

## Three layers

1. **Engine (this repo, repo-agnostic).** `plugins/agent-ops/scripts/` (`common.ps1`, `agent-config.ps1`
   loader, `agent_token.py`, `cleanup.ps1`, `run-*.ps1`, `install-tasks.ps1`, `ai_review.py`),
   `hooks/`, the generalized `playbooks/`, and the `review/` checklists. Contains **no** repo identity
   or machine paths.
2. **Per-repo config (in each consuming repo, `.agent-ops/`).** `config.json` (committed identity +
   labels + roleHeaders + verify + cap), `config.local.json` (**gitignored** machine paths),
   `REPO-FACTS.md` (the repo's contract files / required checks / conventions), `REVIEW-CHECKLIST.md`
   (the project's AI-review checklist).
3. **Runtime state (in each consuming repo, gitignored).** `.claude/agent-state/` — backoff, locks, logs.

`agent-config.ps1` is the **loader**: given a repo (via `$env:AGENT_OPS_REPO` or cwd), it reads
`config.json` merged over `config.local.json`, validates, and sets the script-scope variables
`common.ps1` consumes (`$RepoSlug`, `$AppId`, `$Labels`, `$RoleHeaders`, `$GH`, `$StateDir`, …). The
behavior of `common.ps1` is identical to the original hardcoded version — proven by the golden-master
parity suite in `tests/config.Tests.ps1`.

## Control flow

**Loops (local):** a Windows scheduled task runs `run-<loop>.ps1 -RepoRoot <repo>`. The wrapper sets
`AGENT_LOOP=1` + `AGENT_OPS_REPO`, dot-sources the plugin's `common.ps1` (which loads the repo config),
mints the App token, runs a **deterministic pre-check** (pure `gh`, no LLM), and only then launches
`claude -p /<skill>`. The skill reads the bundled playbook + the repo's `REPO-FACTS.md` and does the work.

**AI review (cloud):** the consuming repo's thin `.github/workflows/ai-review.yml` calls the kit's
`ai-review-reusable.yml`. That reusable workflow checks out the caller repo (for the diff) **and** the
public kit (for `ai_review.py` + base checklists), assembles the checklist (base + the repo's
`REVIEW-CHECKLIST.md` + a conditional agent-ops checklist), sends the diff + prior thread to Claude, and
posts a `[Reviewing Agent]` comment. It is conversation-aware: it skips points already addressed.

## Packaging

- **Plugin** (`plugins/agent-ops/`) — installed via the `boaz-agent-ops` marketplace; enabled per
  project so the guardrail hook scopes to opted-in repos.
- **Reusable workflow** (`.github/workflows/ai-review-reusable.yml`) — one source of truth for the
  reviewer; consumers reference it (the public repo needs no token to be checked out).

## Guardrails

- `hooks/block-dangerous-commands.ps1` (wired) — blocks merge/approve, repo admin, push-to-`main`,
  force-push, recursive delete, machine ops, scheduled-task changes, `.github/workflows/**` edits, and
  — under `AGENT_LOOP=1` — `.agent-ops/**`. Fail-open.
- `hooks/block-sensitive-files.ps1` (shipped, wire globally) — blocks reading/writing secrets.
- GitHub-side: non-admin App + branch protection — the backstop that makes "cannot merge" true.

See [ONBOARDING.md](ONBOARDING.md) to add a repo and [SECURITY.md](SECURITY.md) for the threat model.
