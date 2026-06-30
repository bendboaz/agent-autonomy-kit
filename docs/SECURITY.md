# Security model

## The core guarantee

Agents act under a **non-admin GitHub App**, never as the human. Because the App is not an admin and
`main` is **branch-protected**, the App **physically cannot merge, approve, change protection, or push to
`main`** — enforced by GitHub, independent of agent behavior. The human is the only one who merges.

### Precondition: public repo + branch protection
The guarantee depends on branch protection being **on**. On GH plans where private repos cannot have
branch protection, a consuming repo must be **public**. Onboarding a private repo without protection
removes the core safety property — `install-tasks.ps1` prints this reminder, and onboarding must not
proceed without it.

## Defense in depth (local loops)

`hooks/block-dangerous-commands.ps1` (wired by the plugin) blocks the *operation* regardless of which
credential is in play — so even if a loop fell back to a human token, it still cannot merge/approve, do
repo admin, push to `main`, force-push, recursively delete, touch the machine, change scheduled tasks,
edit `.github/workflows/**` or the permission allowlist, or (under `AGENT_LOOP=1`) edit `.agent-ops/**`.
It **fails open** (a hook bug never bricks a session); the GitHub-side guards remain the backstop.

`hooks/block-sensitive-files.ps1` blocks reading/writing secrets (`.env`, keys, `.pem`, certs). It is
shipped here but **not wired by the plugin** — wire it globally (it is a machine-wide concern). The App
private key is read only by `agent_token.py` from `GH_APP_PRIVATE_KEY_PATH`; it is never logged or
committed.

A hook denial is a **hard stop**: escalate, never reword/obfuscate a command to slip past a guardrail.

## This repo is public — secret hygiene

- **Never commit** a `.pem`, token, API key, or absolute machine path. App ID + Installation ID are
  **identifiers, not secrets** and may be committed in a consuming repo's `config.json`.
- Machine paths (worktree base, venv, gh path) live only in the **gitignored** `config.local.json` or in
  `*.example` files with placeholders.
- Before any push, scan the diff for `.pem`, token prefixes (`ghs_`/`gho_`/`ghp_`/`sk-`), private-key
  headers, and stray `C:\Users\...` / `D:\Users\...` absolutes.

## AI reviewer — prompt-injection surface

`ai_review.py` consumes attacker-influenceable input (a public PR's diff + comment thread) and posts a
comment. It is **materially safer** than the January-2026 `claude-code-action` flaw
([advisory](https://flatt.tech/research/posts/poisoning-claude-code-one-github-issue-to-break-the-supply-chain/)),
because it:
- **never executes model output** — it only formats it into a PR comment;
- runs least-privilege (`contents: read` + `pull-requests: write`), holding no exfiltratable secret
  beyond the API key (which it never echoes).

Keep it that way: do **not** add tool-use / command-execution to the reviewer; pin the reusable workflow
by tag or SHA when you cut a release; keep `permissions:` minimal.

## If you adopt cloud loops later

The local loops bill as Claude Code subscription usage and run on this machine. A cloud path
(`anthropics/claude-code-action`) bills as API and has a larger injection surface — if adopted, use
≥ v1.0.94, require a human actor, never set `allowed_non_write_users: "*"`, and pin the action SHA.
