This diff changes the repo's agent-ops config/playbook path. Apply these extra checks:

  (PowerShell correctness)
    - No `&&` command chaining (Windows PowerShell 5.1 has no pipeline chain operators) — use `;` or
      `if ($?) { ... }`.
    - No `2>&1` on native `git`/`gh` — in PS 5.1 it wraps stderr as ErrorRecord and can false-fail `$?`.
    - Multi-line `gh` bodies must use `--body-file` with a temp file, not inline here-strings.
    - Keep shipped `.ps1` ASCII-only (PS 5.1 mis-reads non-ASCII in a no-BOM file).

  (Label ownership)
    - Only the dispatcher writes the `in-progress` label.
    - Only a human writes `ready`, `priority:*`, or `blocked`. FLAG any script that violates this.

  (Token minter — agent_token.py, if changed)
    - JWT signing uses the correct algorithm + claims; `requests` has error handling + timeouts; no
      secret (key, token) is ever logged.

  (Config)
    - No repo-specific identity or machine paths hardcoded in the shared engine — they belong in
      `.agent-ops/config.json` / `config.local.json`.
