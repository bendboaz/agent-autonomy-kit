# agent-ops (Claude Code plugin)

The autonomous GitHub agent-ops plugin. Install via the `boaz-agent-ops` marketplace, then enable it
**per project** (it ships `defaultEnabled: false` so the guardrail hooks only govern repos you opt in).

## Components

- `skills/` — the loop playbooks Claude invokes: `dispatch-ready-issues`, `babysit-prs`,
  `triage-backlog`, `orchestrate-agent-ops`, `parallel-agent-orchestration`.
- `commands/` — thin slash-command entry points.
- `hooks/` — `block-dangerous-commands.ps1` (deny-gate for the loops) and `block-sensitive-files.ps1`
  (secret-file guard), wired in `hooks/hooks.json` via `${CLAUDE_PLUGIN_ROOT}`.
- `scripts/` — the engine:
  - `common.ps1` — shared helpers (auth, gh queries, dispatch selection, PR-attention classifier,
    worktrees, comment posting, verify, backoff, locks).
  - `agent-config.ps1` — **config loader** (reads a consuming repo's `.agent-ops/config.json`).
  - `agent_token.py` — GitHub App installation-token minter.
  - `cleanup.ps1`, `dispatch-recovery.ps1`, `run-{dispatch,babysit,triage}.ps1`,
    `install-tasks.ps1` / `uninstall-tasks.ps1`.
  - `ai_review.py` — conversation-aware PR reviewer (also driven by the kit's reusable workflow).
- `playbooks/` — generic `OPERATIONS/DISPATCH/BABYSIT/TRIAGE/ORCHESTRATOR/ESCALATION.md`.
- `review/` — `base-checklist.md` + `agent-ops-checklist.md` (kit-owned review checklists).
- `templates/` — starter `.agent-ops/` files + the `ai-review.yml` caller stub for new repos.
- `tests/` — Pester (`common.Tests.ps1`) + pytest (`test_agent_token.py`, `test_ai_review.py`).

## Per-repo config contract

Everything repo-specific lives in the **consuming** repo under `.agent-ops/` — never here. See
`templates/config.example.json` and `../../docs/ONBOARDING.md`.
