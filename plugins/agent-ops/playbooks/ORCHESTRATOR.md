# Orchestrator playbook

> **Generic agent-ops playbook.** Repo-specific facts — the GitHub App / installation IDs, required CI
> checks, local-verify commands, frozen/contract files, and conventions — come from **this repo's
> `.agent-ops/config.json` and `.agent-ops/REPO-FACTS.md`**. Concrete examples below (task names,
> `frontend`/`backend`, issue numbers) are from the reference repo; always defer to this repo's files.

The **orchestrator** is the human's interactive Claude session that manages this repo and oversees the
three autonomous loops — **triage** ([TRIAGE.md](TRIAGE.md)), **dispatch** ([DISPATCH.md](DISPATCH.md)),
**babysitter** ([BABYSIT.md](BABYSIT.md)) — defined against the shared contract
([OPERATIONS.md](OPERATIONS.md)). It runs **interactively** (no `AGENT_LOOP` env var), which is what
lets it edit `.agent-ops/**` (the playbook is orchestrator-only — the loops are blocked by the
deny-hook; see OPERATIONS.md §3 rule 6).

## What only the orchestrator does
- **Edit the playbook** (`.agent-ops/**`): procedures, the token minter, cleanup, wrappers, this
  file. A `ready` issue whose fix would change the playbook must be **escalated**, not built by a loop.
- **Decompose / groom** large work, set policy, and drive multi-loop changes through PRs.
- **Run the loops on demand** + own the schedules. **Never merges** (the human merges); never bypasses
  the App-identity / branch-protection guards.

## Hard limits — never do these autonomously
- **Never apply the `ready` label to any issue.** `ready` means "approved for the auto-dispatcher to
  build" and is the human's decision exclusively. When proposing a new issue or promoting a nit cluster
  to a work item, create the issue with `enhancement` (and `priority: *` as appropriate) and **stop
  there**. Surface it to the human and let them add `ready` if they agree it's dispatchable.

## The loops at a glance
| Loop | Wrapper | Cadence | Writes |
|---|---|---|---|
| Triage | `run-triage.ps1` | nightly | the `🗂️ Backlog triage` report; **grooms `help wanted` issues** (expand body + analysis comment, split into children). Never gating labels, never closes (TRIAGE.md §5b) |
| Dispatch | `run-dispatch.ps1` | every 2h | claims `ready` issues → parallel PRs (independent subset, up to the configured cap `defaultCap`) |
| Babysitter | `run-babysit.ps1` | hourly | drives `claude/agent/issue-*` PRs to clean review (one round/run) |

Each wrapper: mints the App token, sets `AGENT_LOOP=1`, deterministic pre-check (only spins the LLM
when there's work), `--model sonnet`, `--add-dir <worktree base>`, exponential backoff on usage limits.

---

## HEALTHCHECK — run periodically (and after any loop run)

Goal: confirm the loops are making correct progress and **not messing things up**. Do not trust a
loop's self-report — **verify against GitHub + git state**. (`$gh = $GH`,
`$slug = "$RepoSlug"`; mint the App token first.)

1. **Stale locks.** Any issue labelled `in-progress` with **no open linked PR** = a crashed/abandoned
   claim → clear it.
   `gh issue list --repo $slug --label in-progress --json number` → for each, confirm an open
   `claude/agent/issue-N` PR exists; if not, `gh issue edit N --remove-label in-progress`.

2. **Orphan worktrees / branches.** `git worktree list` and `git branch --list claude/agent/issue-*`
   should map 1:1 to **open** agent PRs. Anything else (finished/abandoned) → `cleanup.ps1` prunes
   merged ones; manually `git worktree remove --force` / `git branch -D` true orphans (no PR at all).

3. **Convergence integrity (the over-claim guard).** For each open agent PR, do NOT assume "review
   addressed" — check the **latest** `🔎 [Reviewing Agent]` comment is actually clean or has a newer
   `🛠️`/`👤` reply that resolves it. A `🔎` newer than the last reply = an unaddressed round (the
   babysitter will take it next run; if it's been ≥ the cap of 4 rounds, expect a `needs-attention`
   escalation — verify it escalated rather than silently looping). **`ai-review` check = pass means the
   workflow ran, NOT that the review found nothing — always read the comment.**

4. **Off-limits edits.** No `claude/agent/issue-*` PR diff may touch `.agent-ops/**`,
   `.github/workflows/**`, or a contract file (OPERATIONS.md §7). Spot-check: `gh pr diff N
   --name-only` on agent-branch PRs only. The deny-hook blocks these when `AGENT_LOOP=1`.
   **Exception — supervised sessions:** PRs opened under direct human supervision (no `AGENT_LOOP`,
   branch not named `claude/agent/issue-*`) for issues explicitly tasked with CI or agent-ops work
   are expected to touch those paths. Confirm the branch name and issue intent; if both match, it is
   not a violation — note it and move on. A hit on a true `claude/agent/issue-*` branch means the
   deny-hook was bypassed; investigate.

5. **Stuck / failing PRs.** Open agent PRs with a required check (`frontend`/`backend`) failing across
   multiple rounds, or `needs-attention` set, are the human's queue → surface them. Confirm the
   babysitter's commit-cap/circular-breaker fired rather than churning. For each `needs-attention` item,
   check the escalation followed [`ESCALATION.md`](ESCALATION.md): one role-headed comment with context
   + alternatives + a resume point, clean state (no orphan worktree / half-applied edit), no duplicates.

6. **Concurrency + independence.** Open `claude/agent/issue-*` PRs ≤ the configured cap (`defaultCap`). No two open agent PRs
   should edit the same files (independence filter held) — if they do, expect merge conflicts; flag.

7. **Backoff state.** `Get-ChildItem .claude/agent-state/*.backoff` — a present, future-dated file means
   a loop hit usage limits and is backing off (expected to self-clear). Persistent backoff → investigate
   limits.

8. **Triage freshness + grooming integrity.** The `🗂️ Backlog triage` issue (its number is per-repo) should be recently
   updated; its `ready` candidates reflect the current backlog. Spot-check that triage stayed in
   bounds (TRIAGE.md §5b): it must **not** have applied/removed a gating label or closed any issue, and
   its `help wanted` grooming must be **additive** (analysis appended below the human's text, parents
   left open). Verify a `help wanted` issue it claims to have groomed actually carries a fresh
   `🛠️` analysis, and that any split created real, well-specced children linked from the parent.

8b. **Review-nit ledger.** Scan the `🧹 Review nit ledger` issue (the babysitter logs merge-ready PRs'
   leftover Low nits there, BABYSIT.md §7). A nit recurring across several PRs is a systemic signal →
   propose a cleanup issue (label `enhancement`/`priority: low`) and surface it to the human — **do not
   apply `ready`** (see Hard limits above). The human decides if it's worth dispatching.

9. **Schedules.** `schtasks /Query /TN "agentops-*" /V /FO LIST` — tasks present, `Status: Ready`,
   sane `Next Run Time`, and `Last Result` 0. A non-zero last result → read that run's wrapper output.

10. **Merge queue.** Surface every green, review-clean, `MERGEABLE` agent PR to the human (the loops
    never merge). Stale agent PRs that sat for days → decide merge vs close.

### Remediation quick-reference
- Stale `in-progress` → remove the label. Orphan worktree/branch → `cleanup.ps1` / manual remove.
- Loop went off the rails (wrong fix, scope creep, circular) → add `needs-attention` (parks it from the
  babysitter), comment why, and fix or close the PR yourself.
- A bad merge / lost changes (e.g. a conflict that erased prior work) → rebase the offending branch onto
  current `main`, resolving to keep **all** changesets; verify with a net diff before pushing.
- Need to change a loop's behavior → edit `.agent-ops/**` (orchestrator-only) via a PR; never let a
  loop edit its own playbook.
- Runaway loop → disable its scheduled task (`schtasks /Change /TN "agentops-<loop>" /DISABLE`).

See also: [[agent-autonomy-plan]] memory for current state, and the `parallel-agent-orchestration`
skill for the build-from-scratch methodology.
