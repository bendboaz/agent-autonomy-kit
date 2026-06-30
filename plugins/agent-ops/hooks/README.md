# agent-ops hooks

- **block-dangerous-commands.ps1** — the agent-ops deny-gate. **Wired** by `hooks.json` (PreToolUse on
  `Bash|PowerShell|CMD|Edit|Write`). Blocks merge/approve, repo admin, push-to-`main`, force-push,
  recursive delete, machine ops, scheduled-task changes, edits to `.github/workflows/**`, the permission
  allowlist, the guardrail hooks themselves, and — when `AGENT_LOOP=1` — the per-repo `.agent-ops/**`.
- **block-sensitive-files.ps1** — a machine-wide secret-file guard (blocks reading/writing `.env`, keys,
  `.pem`, certs). **Not wired by this plugin**, to avoid duplicating a hook you may already run globally.
  If you don't have it globally, add it to your user `settings.json` (PreToolUse, matcher
  `Read|Edit|Write|Bash|PowerShell|CMD`) pointing at this copy, or copy it into your global hooks dir.

Both **fail open** — a hook bug never bricks a session. The GitHub-side guards (non-admin App + branch
protection) remain the backstop, so the deny-gate blocks the *operation* regardless of which credential
is in play.
