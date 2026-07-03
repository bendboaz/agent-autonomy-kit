# PR Babysitter — review-response loop

> **Generic agent-ops playbook.** Repo-specific facts — the GitHub App / installation IDs, required CI
> checks, local-verify commands, frozen/contract files, and conventions — come from **this repo's
> `.agent-ops/config.json` and `.agent-ops/REPO-FACTS.md`**. Concrete examples below (e.g. `npm`/`tsc`,
> `frontend`/`backend`, `src/...`) are from the reference repo; always defer to this repo's files.

Drives each open `claude/agent/issue-*` PR to a **clean, mergeable review** — **including substantive
code changes/additions**, not just mechanical nits — using a **bounded, one-iteration-per-run loop**.
Escalates only when genuinely blocked (contract-file change, product decision, iteration cap, or going
in circles).

Shared contract (identity, labels, role headers, escalation, Windows gotchas, contract-file
definition): [`OPERATIONS.md`](OPERATIONS.md). This doc is the step-by-step procedure on top of it.

## Run model — one iteration per run

Each scheduled run performs **at most one round** of fixes per PR: read the current state → make the
needed changes → verify → **one push** → reply. That push triggers a fresh CI + AI-review; the **next**
scheduled run sees the new review round and continues. Convergence is therefore spread across runs, and
the **iteration cap counts rounds across runs** (§4), not pushes within a run. This keeps each run short
and crash-safe (no long-held session polling CI).

---

## 1. Preconditions

**When launched by `run-babysit.ps1`** (the normal path): `Initialize-AgentAuth` (`common.ps1`) has
already minted `GH_TOKEN`, verified the auth identity, pruned stale worktrees (`cleanup.ps1`), and
ensured the worktree base dir exists — before this playbook is even read. Nothing in this section
needs to run.

**Manual / no-wrapper run only** — check for an existing token first, mint only if missing:
```powershell
if ($env:GH_TOKEN -notlike 'ghs_*') {
    $env:GH_APP_ID              = "<appId in .agent-ops/config.json>"
    $env:GH_APP_INSTALLATION_ID = "<installationId in .agent-ops/config.json>"
    # GH_APP_PRIVATE_KEY_PATH must already be set as a user-scope env var — do NOT set it here
    # (.pem extension triggers the sensitive-file hook; see OPERATIONS.md §1)
    $env:GH_TOKEN = (python the agent-ops plugin's scripts/agent_token.py)   # safe — no .pem in command
}
& $GH auth status   # must show the App, not the human
```
Token is short-lived (~10 min); re-mint mid-run: `$env:GH_TOKEN = (python the agent-ops plugin's
scripts/agent_token.py)`.

---

## 2. Select PRs

List open PRs whose head branch matches `claude/agent/issue-*` (the autonomous lane — never touch
interactive `claude/...` branches), with CI, review, and mergeability state.

```powershell
$gh   = $GH
$slug = "$RepoSlug"
$prs  = & $gh pr list --repo $slug --state open `
  --json number,headRefName,mergeStateStatus,reviewDecision,statusCheckRollup,labels | ConvertFrom-Json
$agentPRs = $prs | Where-Object { $_.headRefName -match '^claude/agent/issue-' -and ($_.labels.name -notcontains 'needs-attention') }
```
Skip PRs already labelled `needs-attention` (a human owns them until they clear it). A PR **needs a
round** this run if any of: `mergeStateStatus` in `BEHIND/DIRTY/UNSTABLE`; a required check
(`frontend`/`backend`) concluded failure; `reviewDecision = CHANGES_REQUESTED`; **or** there is a
`🔎 [Reviewing Agent]` comment with no newer `🛠️ [Implementing Agent]` / `👤 [Human]` reply (an
unaddressed review round). The wrapper's deterministic gate (`run-babysit.ps1`) checks this before
launching, so if you are running you have work to do.

---

## 3. One iteration: rebase → fix CI → address review

Do all work for a PR in a **dedicated worktree** so the main checkout is never disturbed:

```powershell
$n = <issue number>; $branch = "claude/agent/issue-$n"
$repoRoot = "the repo root"
$wt       = "the configured worktree base\issue-$n"   # matches the allowlist + --add-dir grant
git -C $repoRoot fetch origin main
if (-not (Test-Path $wt)) { git -C $repoRoot worktree add $wt $branch }
Set-Location $wt
```

### 3a. Rebase if behind
```powershell
git rebase origin/main
```
Resolve **trivial** conflicts (lockfiles → regenerate; import-order/whitespace; generated CSS → rebuild).
A conflict involving **real overlapping logic** → escalate (§6), `git rebase --abort`.

### 3b. Fix failing CI
Read the failing job (`gh run view <id> --log-failed`). **Fix the actual cause** — lint/format/type
errors, *and* genuine logic/test failures within the linked issue's scope. Re-run only for clearly
transient/flaky failures. Escalate (§6) only if the fix needs a contract-file change or a product
decision.

### 3c. Address the AI review (the core)
Fetch the thread; for every `🔎 [Reviewing Agent]` finding **not yet addressed** by a newer
`🛠️`/`👤` reply, **make the change it asks for** — mechanical *or* substantive (real code, new tests).
Prefer staying **within the linked issue's scope**; you MAY change code **outside** that scope **only
when it is directly required to resolve a review finding** (e.g. fix production code so a flagged gap
becomes testable) — keep such changes **minimal and consistent with existing patterns**, never broad
refactors. Always obey the **contract-file rules** (OPERATIONS.md §7). This is the key difference from a
mechanical-only babysitter: you resolve the review, you don't punt it.

```powershell
$thread = (& $gh pr view $n --repo $slug --json comments | ConvertFrom-Json).comments
$thread | ForEach-Object { "--- $($_.author.login) $($_.createdAt) ---`n$($_.body)`n" }
```

- For a finding you **can** resolve in-scope: implement it, keeping changes minimal and matching repo
  conventions (`CLAUDE.md`: no `any` to silence the compiler, theme CSS vars, etc.). If a finding is
  large/independent, prefer a focused, correct change over a sprawling one.
- For a finding you **should not** act on (needs a genuine product/design decision, is pre-existing /
  flagged not-introduced-here, or would need broad out-of-scope changes beyond a minimal required fix):
  don't force it — note it in the reply
  and, if it blocks merge, escalate (§6). A reviewer "looks good / no blocking issues" needs no code
  change — just acknowledge it (which advances the thread so the gate won't re-fire).
- **Cover the whole finding, and verify before claiming.** When a finding cites a pattern that recurs
  across files or lines ("same in X and Y", "throughout", "both files"), fix **all** instances, not
  just the cited one. Before stating in your `🛠️` reply that a finding is addressed, **verify the change
  is actually present and effective** (re-read the file / run the relevant check) — report only what you
  verified, never a partial or assumed fix. A partial or over-claimed fix just bounces back next round
  (and burns an iteration toward the cap).

### 3d. Verify locally
Before pushing, all required checks must pass locally:
```powershell
npm ci; npx tsc --noEmit; npm run build; npm test     # + pytest in backend/ for backend changes
```

### 3e. Reply with a role-headed summary — BEFORE pushing
Post one `🛠️ [Implementing Agent]` comment (via `--body-file`) **before** the push, listing per
review finding: what you changed (file/why) or — for anything you intentionally left — the reason.

Posting the reply before the push is the primary mitigation for the AI-review timing race (§5):
the push triggers the `ai-review.yml` workflow, which fetches the comment thread shortly after
the job starts. If the reply is already in the thread at that point, the reviewer sees it and
skips the resolved finding. Then wait briefly for GitHub to propagate the comment before pushing:

```powershell
# Post the reply first (before push — see §5)
# Use a fixed no-space temp path; if Remove-Item is blocked by a guardrail, leave the file
$tmp = "$env:TEMP\cc-reply.txt"
@"
🛠️ **[Implementing Agent]**

Addressed findings from the latest review:
<!-- fill in: per-finding summary -->
"@ | Set-Content -Path $tmp -Encoding utf8
& $gh pr comment $n --repo $slug --body-file $tmp
Remove-Item $tmp -ErrorAction SilentlyContinue

# Brief propagation buffer so the comment is visible before the review job starts
Start-Sleep -Seconds 15

# Then push — triggers fresh CI + AI-review
git push --force-with-lease origin $branch    # (plain push if no rebase happened)
```

---

## 4. Iteration cap + circular / no-progress guard

The loop is **bounded by rounds across runs**, not pushes within a run.

- **Round count** = number of `🛠️ [Implementing Agent]` reply comments already on the PR. **Cap = 4.**
- If rounds **≥ cap** and the PR is still not clean → **escalate** (§6): "addressed N rounds; not
  converged." Stop.
- **Circular / no-progress:** if the newest review **re-raises a finding a prior `🛠️` reply claimed to
  resolve**, or successive High/Medium rounds keep surfacing issues with no net reduction → you are
  likely going in circles → **escalate**. Do **not** re-apply a fix the thread shows was already made (§5).
- **Only High/Medium drive the loop.** Low-severity nits do **not** count toward convergence or the cap.
  Once no unaddressed **High/Medium** findings remain, the PR is **done** (§7) even if Low nits persist —
  this stops the loop churning on the endless Low nits an LLM reviewer tends to surface.

This is the "solve High/Medium, then stop; hit the cap or detect circling → escalate" bound: the
babysitter iterates across runs until no High/Medium remain, but never indefinitely.

---

## 5. AI-review timing race

`ai-review.yml` snapshots the comment thread shortly after a push triggers the job. If the reply
arrives after that snapshot, the reviewer may re-raise points that were already addressed.

**Primary fix (§3e):** post the `🛠️ [Implementing Agent]` reply **before** pushing, then wait
`Start-Sleep -Seconds 15` before the `git push`. This ensures the comment is already in GitHub's
API when the review job fetches it. This covers all babysitter re-run cases (where the PR already
exists). For the initial PR push there is no existing review thread, so there is no race to fix.

**If a run still re-raises an already-resolved point** (residual stale snapshot or very fast job
start), confirm the reply is in the thread and **do not re-fix it** — distinguish this (a
stale-snapshot artifact) from genuine circling (§4) before escalating. Optionally re-trigger the
review to get a clean read:
```powershell
& $gh workflow run ai-review.yml --repo $slug --ref $branch
```

---

## 6. Escalation (narrowed)

Follow the shared **[`ESCALATION.md`](ESCALATION.md)** runbook (stop → stabilize → finish independent
WIP → gather context → offer alternatives → alert, idempotently). The babysitter-specific points:

Escalate — `needs-attention` label on the PR + a `🛠️ [Implementing Agent]` comment stating exactly
what's blocked + a `PushNotification` — then **stop on this PR** and move on. Escalate **only** when:

- A fix would require editing a **contract file** (OPERATIONS.md §7), `.github/workflows/*`, or the
  **orchestrator-only** playbook `.agent-ops/**` (OPERATIONS.md §3 rule 6).
- The feedback needs a genuine **product/design decision**, or is **out of the linked issue's scope**.
- **Iteration cap** (§4) reached, or **circular / no-progress** detected.
- A rebase conflict involves **real overlapping logic**.

```powershell
& $gh pr edit $n --repo $slug --add-label "needs-attention"
# Use a fixed no-space temp path; if Remove-Item is blocked by a guardrail, leave the file
$tmp = "$env:TEMP\cc-escalate.txt"
@"
🛠️ **[Implementing Agent]**

Escalating — human attention required.

**Reason:** <fill in what's blocked and what you tried>
"@ | Set-Content -Path $tmp -Encoding utf8
& $gh pr comment $n --repo $slug --body-file $tmp
Remove-Item $tmp -ErrorAction SilentlyContinue
# then send a PushNotification with a one-line summary + the PR URL
```

**Hard limits (never):** approve a PR; merge; force-past a failing required check; edit
`.github/workflows/*` or `.agent-ops/**` (orchestrator-only); change branch protection / rulesets
/ secrets; edit issues or their labels (except adding `needs-attention` on the PR); touch a branch that
isn't `claude/agent/issue-*`.

---

## 7. Done state — merge-ready

A PR is **merge-ready** when: `frontend` + `backend` checks are `SUCCESS`; `mergeStateStatus` is `CLEAN`
(not behind/dirty); and there are **no unaddressed High/Medium** `🔎 [Reviewing Agent]` findings. **Low
nits do not block merge-ready** — an LLM reviewer surfaces them endlessly, so don't chase them in the
loop (§4). When merge-ready holds, post a brief `🛠️` "merge-ready" note (listing any remaining Low
nits) and `PushNotification`: `"PR #N '<title>' is green, no High/Medium open, ready to merge. <url>"`.
**The babysitter never merges — the human does.**

### Low-nit ledger
When you mark a PR merge-ready with Low nits still open, **log them** so recurring ones become visible
across PRs (and can be batch-cleaned when there's time). Append to a single open issue titled
**`🧹 Review nit ledger`** (find-or-create, like the triage report) — one short entry per PR: PR #, date,
and each remaining Low nit (file:line + one line). Do **not** fix them now. If the same nit recurs across
several PRs in the ledger, that's a signal to promote it to a real `ready` issue (orchestrator/triage).
```powershell
# find-or-create the ledger, then append (edit body via --body-file)
$ledger = & $gh issue list --repo $slug --state open --search "Review nit ledger in:title" --json number | ConvertFrom-Json
```

---

## 8. Cleanup

Remove the worktree you created when done with this run's PR:
```powershell
Set-Location $repoRoot
git worktree remove "the configured worktree base\issue-$n" --force
```
The branch persists until its PR merges/closes, then is pruned by `cleanup.ps1` (OPERATIONS.md §9).
