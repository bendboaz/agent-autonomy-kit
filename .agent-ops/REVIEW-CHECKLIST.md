# AI review checklist — bendboaz/agent-autonomy-kit

Project-specific checks appended to the kit's base checklist when the AI reviewer runs on a PR.

## PowerShell engine correctness

- No `&&` command chaining — Windows PowerShell 5.1 has no pipeline chain operators; use `; if ($?) { }`.
- No `2>&1` on native `git`/`gh` — PS 5.1 wraps stderr as `ErrorRecord`, can false-fail `$?`.
- Multi-line `gh` comment bodies must use `--body-file <temp path>`, never inline here-strings.
- Shipped `.ps1` files: ASCII-only body (no bare non-ASCII without a BOM guard) so PS 5.1 reads them correctly.

## Secret hygiene (public repo — non-negotiable)

- No absolute machine paths (`D:\`, `C:\Users\`) in committed files. Machine paths belong in
  `.agent-ops/config.local.json` (gitignored) or `*.example` files with placeholder values.
- No App tokens (`ghs_`, `gho_`, `ghp_`), API keys (`sk-`), or private-key headers.
- No `.pem` files anywhere in the tree. `GH_APP_PRIVATE_KEY_PATH` is a user-scope env var only.
- App ID (`4070567`) and Installation ID (`140736715`) are identifiers (public) — they MAY appear
  in committed `config.json` and test fixtures.

## Golden-master parity

- `agent-config.ps1` loader must produce the same variable values as the `tests/fixtures/dnd/` baseline.
- `Get-DispatchableIssues` and `Get-PRsNeedingAttention` must return byte-identical results on the
  same injected fixtures as the original hardcoded constants did. Never "improve" behavior silently
  during extraction — that is a separate, deliberately reviewed change.
- The `config.Tests.ps1` suite must stay green after any loader edit.

## Plugin manifest consistency

- `name` in `plugins/agent-ops/.claude-plugin/plugin.json` must match the entry in
  `.claude-plugin/marketplace.json`.
- `version` field is intentionally absent (SHA-versioned during active development). Do not add it.
- `hooks/hooks.json` uses `${CLAUDE_PLUGIN_ROOT}` for the hook script path — no hardcoded paths.

## Recurring catches

- Config fields that `common.ps1` consumes (`$Labels`, `$RoleHeaders`, `$WorktreeBase`, `$GH`,
  `$StateDir`) must be set by the loader before any `common.ps1` function is called.
- `Get-AgentProp` helper is needed for PSCustomObject property access in PowerShell 5.1 — direct
  `.property` access on `ConvertFrom-Json` objects can silently return `$null` on older PS.
