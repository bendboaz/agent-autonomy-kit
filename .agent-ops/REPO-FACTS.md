# REPO-FACTS — bendboaz/agent-autonomy-kit

Repo-specific facts the agent-ops playbooks defer to (OPERATIONS.md §7).

## Repository & branch protection

- **Repo:** `bendboaz/agent-autonomy-kit` — public; branch protection on `main` (PR + 1 approval,
  no self-approve, required checks must pass, dismiss-stale, `enforce_admins=false`). The App cannot
  merge; the human merges.
- **Notes:** The "App cannot merge" guarantee is what this kit is designed to demonstrate — so this
  repo must itself honour it.

## Required CI checks

| Check name | What it runs |
|---|---|
| `manifests` | `python -c "import json; json.load(open('.claude-plugin/marketplace.json')); ..."` |
| `pester` | `pwsh` → `Install-Module Pester`; `Invoke-Pester -CI -Path tests` in `plugins/agent-ops/` |
| `python` | `pip install -r requirements.txt pytest`; `pytest tests` in `plugins/agent-ops/` |

All three must be green before a PR is mergeable.

## Local verification (before opening a PR)

From the repo root (Windows PowerShell):
```powershell
# Validate manifests
python -c "import json; json.load(open('.claude-plugin/marketplace.json')); json.load(open('plugins/agent-ops/.claude-plugin/plugin.json')); print('manifests OK')"

# Pester (requires pwsh ≥ 7)
pwsh -NoProfile -Command "Install-Module Pester -MinimumVersion 5.5.0 -Force -Scope CurrentUser; Invoke-Pester -CI -Path plugins/agent-ops/tests"

# Python
pip install -r plugins/agent-ops/requirements.txt pytest -q
pytest plugins/agent-ops/tests
```

## Conventions (enforced by review + guardrail hook)

- **PowerShell syntax:** no `&&` (use `; if ($?) {}`); no `2>&1` on native `git`/`gh` (PS 5.1
  wraps stderr as ErrorRecord); multi-line `gh` bodies via `--body-file`, never inline here-strings.
- **Secret hygiene (public repo — hard rule):** no `.pem`, no tokens, no absolute machine paths in
  committed files. App ID + Installation ID are identifiers (safe to commit). Machine paths live only
  in `.agent-ops/config.local.json` (gitignored) or `*.example` files with placeholder values.
- **Golden-master parity:** the config loader (`agent-config.ps1`) must produce byte-identical
  variable values to the test fixtures in `tests/fixtures/dnd/`. Changing fixture values or loader
  behavior requires a deliberate version bump, not a silent drift.
- **No residual repo-specific identity** in the engine (no `dnd-session-assistant`, no App IDs
  hardcoded in `common.ps1`/skills/playbooks). All identity comes from `.agent-ops/config.json`.
- **Plugin manifest consistency:** `name` in `plugin.json` must match the entry in
  `marketplace.json`. `version` is intentionally omitted (SHA-versioned); do not add it.

## Contract files (frozen)

Changes to the exported shape of these files require the orchestrator's sign-off:
- `.claude-plugin/marketplace.json` — `name`, `owner`, `plugins[].name`, `plugins[].source`
- `plugins/agent-ops/.claude-plugin/plugin.json` — `name` (required by Claude Code plugin system)
- `plugins/agent-ops/hooks/hooks.json` — hook structure (adding/removing hooks changes the guardrail)
- `plugins/agent-ops/tests/fixtures/dnd/` — golden-master fixture files (values are the parity baseline)

Test files (`*.test.ts`, `*.Tests.ps1`, `test_*.py`) are **not** contract-frozen and can be added or
changed freely.
