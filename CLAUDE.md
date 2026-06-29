# CLAUDE.md — agent-autonomy-kit

Repo-agnostic packaging of the autonomous **agent-ops** mechanism originally built inside
`dnd-session-assistant`: three scheduled Claude Code loops (**dispatch** → issues to PRs,
**babysit** → keep PRs green, **triage** → groom the backlog), an interactive **orchestrator**, and a
conversation-aware **AI reviewer** — all acting under a **non-admin GitHub App** so they *physically
cannot merge* (the human merges; `main` is branch-protected). This repo lifts that mechanism out so it
can drive **any** repo, be **version-tracked** (including pieces that used to be local-only), and leave
each consuming repo as a thin client.

## What this repo is

- A **Claude Code plugin** (`plugins/agent-ops/`) bundling the skills, slash commands, guardrail hooks,
  PowerShell engine, token minter, playbooks, and the AI-review script.
- A **marketplace** (`.claude-plugin/marketplace.json`) so the plugin installs via `claude plugin install`.
- A **reusable GitHub workflow** (`.github/workflows/ai-review-reusable.yml`) that any consuming repo
  calls for its AI review.

A **consuming repo** carries only a small `.agent-ops/` folder (config + repo-facts + review checklist)
and a ~6-line `ai-review.yml` caller. See `docs/ONBOARDING.md`.

## Architecture — three layers (keep the seam clean)

1. **Engine (here, repo-agnostic):** `plugins/agent-ops/scripts/common.ps1`, `agent_token.py`,
   `cleanup.ps1`, `run-*.ps1`, `ai_review.py`; the hooks; the skill *procedures*; the playbook
   *templates*. Must contain **no repo-specific literals** (no repo slug, App IDs, machine paths).
2. **Per-repo config (in each consuming repo):** `.agent-ops/config.json` (committed identity +
   labels + verify commands), `.agent-ops/config.local.json` (**gitignored** machine paths),
   `.agent-ops/REPO-FACTS.md` (the repo's contract files / required checks / conventions),
   `.agent-ops/REVIEW-CHECKLIST.md` (the project's AI-review checklist).
3. **Runtime state (in each consuming repo, gitignored):** `.claude/agent-state/` — backoff, locks, logs.

`scripts/agent-config.ps1` is the **loader**: given `-RepoRoot`, it reads `config.json` merged over
`config.local.json`, validates, and sets the script-scope variables `common.ps1` consumes
(`$RepoSlug`, `$AppId`, `$WorktreeBase`, `$Labels`, `$RoleHeaders`, `$GH`, `$StateDir`, …). Behavior of
`common.ps1` must not change — that is what guarantees parity with the original D&D system.

## Golden rule: prove parity, don't change behavior

The deterministic selection logic (`Get-DispatchableIssues`, `Get-PRsNeedingAttention`, backoff, locks)
and the AI-review string assembly are covered by tests with injected fixtures. When generalizing, keep
them **byte-identical** on the same fixtures (golden-master). Never "improve" loop behavior during the
extraction — that is a separate, later change.

## Platform (Windows)

Use the **PowerShell tool** for shell commands (Bash only for `.sh`). `Get-ChildItem` not `ls`/`find`;
`Select-String` not `grep`; `Get-Content` not `cat`/`head`/`tail`; `New-Item -ItemType Directory -Force`
not `mkdir -p`. No `&&` chaining — use `;` or `if ($?) { ... }`. No `2>/dev/null` — use `2>$null`.
Windows paths (`D:\Users\Boaz\CodeProjects\...`), never POSIX. `gh` at
`C:\Program Files\GitHub CLI\gh.exe` (fallback to PATH).

### PowerShell / gh gotchas (carried from the source repo)
- Don't redirect native `git`/`gh` stderr with `2>&1` (PowerShell 5.1 wraps it as NativeCommandError
  and false-fails `$?`).
- Post multi-line `gh` bodies via `--body-file <fixed no-space temp path>`, never here-strings.
- Avoid `gh --jq` with `\(...)`; parse with `ConvertFrom-Json`.

## This repo is PUBLIC — secret hygiene is non-negotiable

- **Never commit** a `.pem`, a token, an API key, or absolute machine paths. The App private key always
  lives **outside any repo** at `GH_APP_PRIVATE_KEY_PATH` (user-scope env). The global sensitive-file
  hook blocks reading/writing `.pem`/keys.
- App ID + Installation ID are **identifiers, not secrets** (already public), but they belong in each
  consuming repo's `.agent-ops/config.json`, not hardcoded in the engine.
- Machine paths (worktree base, venv, gh path) go only in the **gitignored** `config.local.json` or in
  `*.example` files with placeholder values.
- Before any push: scan the diff for `.pem`, `ghs_`/`gho_`/`ghp_`/`sk-`, and stray `D:\` / `C:\` absolutes.

## Consuming-repo precondition: branch protection

The "App cannot merge" guarantee depends on **branch protection on `main`**, which on this GH plan
requires a **public** repo. Onboarding a private repo without branch protection breaks the core safety
property — `docs/SECURITY.md` makes public + branch-protected a hard precondition, and
`install-tasks.ps1` verifies it before registering loops.

## Testing

```powershell
# PowerShell helper unit tests (pure-logic, fixture-injected; cross-platform on pwsh)
Invoke-Pester -CI -Path plugins/agent-ops/tests
# Python: token minter + AI reviewer (Anthropic client mocked)
pip install -r plugins/agent-ops/requirements.txt pytest ; pytest plugins/agent-ops/tests
# Manifest validation
claude plugin validate ./plugins/agent-ops --strict
```

## Layout

```
.claude-plugin/marketplace.json          # marketplace catalog
plugins/agent-ops/                        # the plugin
  .claude-plugin/plugin.json              # manifest (name required; version omitted → SHA-versioned)
  commands/ skills/ hooks/                # auto-discovered Claude Code components
  scripts/                                # engine: common.ps1, agent-config.ps1(loader), agent_token.py,
                                          #   cleanup.ps1, run-*.ps1, install-tasks.ps1, ai_review.py
  playbooks/                              # OPERATIONS/DISPATCH/BABYSIT/TRIAGE/ORCHESTRATOR/ESCALATION (generic)
  review/                                 # base + agent-ops review checklists (kit-owned)
  templates/                              # per-repo config / REPO-FACTS / REVIEW-CHECKLIST / caller stubs
  tests/                                  # Pester + pytest
.github/workflows/                        # kit CI + ai-review-reusable.yml
docs/                                     # ARCHITECTURE / ONBOARDING / SECURITY
```

## Conventions

- PowerShell engine functions stay **pure where possible** and accept injected fixtures (`-Issues`,
  `-OpenPRs`, `-PullRequests`) so they unit-test without a live `gh`. Preserve this when editing.
- Comments explain *why*, not *what*; match the density of the foundation files carried over from D&D.
- Keep `${CLAUDE_PLUGIN_ROOT}` for every in-plugin path referenced by hooks/commands — never hardcode
  the installed plugin location.
