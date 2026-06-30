# REPO-FACTS — &lt;owner/repo&gt;

Repo-specific facts the agent-ops playbooks defer to (OPERATIONS.md §7). Fill this in per repo and keep
it in the consuming repo at `.agent-ops/REPO-FACTS.md`.

## Repository & branch protection
- **Repo:** `<owner/repo>` — must be **public with branch protection on `main`** (that is what makes the
  App physically unable to merge). Protection: PR + 1 approval (no self-approve), the required checks
  below, dismiss-stale, `enforce_admins=false` (an admin human can merge; the App cannot).

## Required CI checks
- The required status checks a PR must pass before it is mergeable (e.g. `frontend`, `backend`). Name
  each and what it runs.

## Local verification (a builder must pass before opening a PR)
- The exact commands a builder runs locally before opening a PR. Keep these in sync with
  `.agent-ops/config.json` → `verify`. Example: `npm ci`, `npx tsc --noEmit`, `npm run build`,
  `npm test`; for backend changes, `pytest` from `backend/`.

## Conventions (enforced by review)
- Project conventions the AI review enforces (styling rules, no `any` to silence the compiler, import
  style, etc.). Point at the repo's `CLAUDE.md` / design doc.

## Contract files (frozen)
- Files whose **exported types/signatures may not change** without human sign-off. List them and any
  carve-outs (e.g. test files exempt). A change to a frozen signature is an **escalation**, not a
  mechanical fix.
