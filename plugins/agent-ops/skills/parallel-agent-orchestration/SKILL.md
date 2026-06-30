---
name: parallel-agent-orchestration
description: >-
  Playbook for orchestrating a build with multiple parallel subagents and GitHub PRs:
  decomposing work into contract-bounded packages, running isolated git worktrees +
  background subagents, integrating, and driving the PR/CI/AI-review loop. Use when the
  user wants to "build this with subagents", "parallelize work across agents", run a
  multi-agent build, or manage a repo via subagents + GitHub. Windows/PowerShell-aware.
---

# Parallel agent orchestration

A field-tested playbook for acting as the **orchestrator**: you decompose, dispatch, integrate, and
gate — subagents implement.

## 1. Decompose into contract-bounded work packages

- Split the work into packages that own **disjoint file sets**. Conflicts come from two agents touching
  the same file, so design ownership to be non-overlapping.
- Write the **seams as explicit contracts first** (interfaces / types / API shapes) and freeze them.
  Agents code *against* contracts, not each other. A package that needs another not built yet uses a
  local **fake/stub** satisfying the contract.
- Put the design + per-package briefs in the repo (`docs/DESIGN.md`, a brief per package): goal, owned
  files, contracts (read-only), acceptance criteria, "commit + report".
- Sequence: **foundation/contracts → parallel features → integration**. Mark dependencies so dependents
  don't start early.

## 2. Isolate with git worktrees

- One worktree per package on its own branch: `git worktree add -b feat/x ..\wt-x main`.
- Each frontend worktree needs its own `npm install` (node_modules isn't shared). Backend worktrees get
  their own venv.
- Clean up when merged: `git worktree remove --force ..\wt-x` (+ delete the branch). The folder may be
  lock-held on Windows — kill stray `node`/`esbuild` then remove.

## 3. Dispatch background subagents

- Spawn with `run_in_background: true`; you get a completion notification (occasionally it doesn't fire —
  verify via git/gh state, don't just wait).
- **Model policy:** implementing agents → **Sonnet**; infra/CI/glue → **Haiku**; reserve the top tier
  for the orchestrator. (Haiku needs an explicit file checklist + a mandatory "commit when done" or it
  derails into reading reference material.)
- **Brief contents (every time):** the OS/shell (Windows → PowerShell tool, Windows paths, no `&&`, no
  `2>&1` on git/gh); the exact worktree path + branch; files it owns; the read-only contract files;
  acceptance criteria; "verify (tsc/build/test), commit with the Co-Authored-By trailer, push, report".
  Self-contained — the agent starts cold.
- A cold subagent on a half-finished/dirty tree is fragile; if one is interrupted, finish the last steps
  yourself rather than re-dispatching onto the mess.

## 4. Integrate

- Merge branches into `main` (or via PRs). Disjoint ownership ⇒ usually conflict-free; the one shared
  file is `package.json` (dep additions) — union it, re-run `npm ci`.
- Reconcile small contract frictions agents report (don't let them edit contracts; they report, you
  decide). Swap fakes for real implementations at the wiring seam.
- Run the full suite on the combined tree before declaring done.

## 5. GitHub PR workflow

- `gh` CLI (install: `winget install GitHub.cli`; auth is interactive — the human runs `gh auth login`
  once). Invoke by full path if not on PATH; new shells need a PATH refresh.
- Protected `main` → all work via PR; **only the human merges**. You open PRs, push fixes, comment —
  never merge.
- **Conversation-aware AI review** (CI calls Claude on the PR diff + prior thread). Pair it with a
  **role-header convention** so bot/human comments are distinguishable (all post from one account):
  `[Reviewing Agent]`, `[Implementing Agent]`, human unprefixed.
- **Review loop:** read the AI review → fix genuine findings (note items deferred to other PRs) → push →
  re-read. Converge to "no High, nothing blocking"; don't chase nano-nits.
- Backlog lives in **GitHub Issues**, not parallel markdown lists. Keep at most one slim local notes
  file; everything independently-workable is an issue with full context.

## Windows / tooling gotchas

- PowerShell: `git`/`gh` write progress to stderr → redirecting `2>&1` trips NativeCommandError and
  false-fails `$?`. Don't redirect; chain with `;`.
- Pass multi-line commit messages / issue bodies via `--body-file` or separate `-m` flags, not
  here-strings (PowerShell mangles `->`, quotes, parens). `gh --jq` with `\(...)` also breaks in
  PowerShell — parse JSON with `ConvertFrom-Json` instead.
- `localhost` can resolve to IPv6 `::1`; target `127.0.0.1` when the server binds IPv4.
- The Vite dev server wedges under tooling — run it in a real terminal you control.
- `npm create vite@latest` may scaffold a non-React template — verify after scaffolding.
