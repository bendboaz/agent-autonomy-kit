# Escalation — shared runbook

> **Generic agent-ops playbook.** Repo-specific facts — the GitHub App / installation IDs, required CI
> checks, local-verify commands, frozen/contract files, and conventions — come from **this repo's
> `.agent-ops/config.json` and `.agent-ops/REPO-FACTS.md`**. Concrete examples below (e.g. `npm`/`tsc`,
> `frontend`/`backend`, `src/...`) are from the reference repo; always defer to this repo's files.

**One order of operations for every headless loop** (dispatch / babysit / triage). *When* to escalate
is defined in [`OPERATIONS.md`](OPERATIONS.md) §5 (the trigger list). **This file is the *how*** — the
same ordered sequence each loop runs so that escalation is clean, predictable, and resumable.

**Principle:** escalation is **not** "give up and dump a problem on the human." It is *"stop safely,
preserve what's good, leave the world tidy, and hand over a decision the human can make in one read."*
A boundary is a stop, not an obstacle to push through.

---

## The order of operations (every loop, every time)

### 0. Stop at the boundary
The moment a trigger fires (OPERATIONS §5), **stop forward progress on that item.** Do **not** retry a
reworded, obfuscated, or hook-dodging version of the blocked action (OPERATIONS §5 — never circumvent a
security/permission hook). Guessing past the boundary is the thing escalation exists to prevent.

### 1. Stabilize the halted action (clean up the midway state)
Leave nothing half-applied. Bring the in-flight action to a consistent state (see the per-loop table in
§"Stabilize specifics"):
- **Undo partial mutations** so state is coherent — abort a conflicted rebase, restore the `main`
  checkout, drop a half-written commit, back out a partial edit.
- **Preserve salvageable work — don't destroy it.** If partial work is sound and is *not itself* the
  blocker, commit it to its branch (or record exactly where it lives) so a later run or the human can
  resume. **Never** push a broken state, and **never** open/merge/approve to "finish past" the blocker.
- **Release anything that would wedge the next run:** stale locks/labels, orphan worktrees, temp files.

### 2. Finish independent, unblocked WIP first
If this run has other items that **don't depend on the blocker**, complete them before escalating —
escalation must never strand otherwise-shippable work. (E.g. the dispatcher escalates one ambiguous
issue but still opens PRs for the independent ones in the batch.)

### 3. Gather context (make the hand-over self-contained)
Assemble, in one place, everything the human needs without digging:
- **What** you were doing and **which trigger** fired.
- **The exact blocker** — error text, failing-job log link, the review finding, the conflict.
- **What you already tried** and why it didn't resolve it.
- **Current state** — branch / PR / issue / worktree, labels, what's committed vs pending, what's clean
  vs in-flight, and **where the salvageable WIP lives**.

### 4. Offer alternatives (frame a decision, don't dump a problem)
Give the human **2–3 concrete options with trade-offs**, plus a **recommendation**. For example:
*"(a) approve the contract-file change in `docs/DESIGN.md`; (b) re-scope the issue to avoid it; (c) I
close this and you re-queue it when ready — recommend (a)."* If there is genuinely one path, state it
and the exact decision you need from the human.

### 5. Alert cleanly (single, idempotent hand-off)
- **Label:** add `needs-attention` to the PR/issue (respecting ownership — OPERATIONS §2/§3).
- **Comment:** **one** role-headed `🛠️ [Implementing Agent]` comment carrying steps 3 + 4 (context +
  alternatives + resume point), via `--body-file` (ASCII, no BOM). If an escalation comment already
  exists, **update/append** — never post duplicates.
- **Notify:** **one** `PushNotification` — one-line reason + the exact URL.
- **Then stop on that item and move on.** Do not loop.

### 6. Leave a resumable trail
The comment states the resume point; labels and locks reflect reality; nothing is silently half-done.
The next scheduled run sees `needs-attention` and **skips the item** — so *the state you leave is the
hand-over.* Make it true.

---

## Idempotency — don't re-escalate
Before escalating, check whether `needs-attention` is **already** set with a current escalation comment.
If so, the human already owns it — **skip; do not repost or re-notify.** Re-escalate only when new
information changes the ask, and then **append** to the existing comment noting what changed.

---

## Standard escalation comment shape
```
🛠️ **[Implementing Agent]**

**Escalating — human decision needed.**

**Trigger:** <which OPERATIONS §5 trigger fired>
**Blocker:** <exact error / finding / conflict, with log or link>
**Tried:** <what you attempted; why it didn't resolve it>
**State:** <branch / PR / issue / worktree; committed vs pending; where salvageable WIP lives>
**Options:**
1. <option A — trade-off>
2. <option B — trade-off>
3. <option C — trade-off>
**Recommendation:** <your pick + one-line why>
```
Then `PushNotification`: `[<Loop>] <item> blocked — <one-line reason>. <URL>`

---

## Stabilize specifics — step 1 per loop
| Loop | In-flight action when blocked | Stabilize / clean up | Preserve |
|---|---|---|---|
| **Dispatcher** | claimed an issue (`in-progress`) and is building in a worktree | If no PR will open, **clear `in-progress`** so the issue is re-dispatchable; remove the orphan worktree and restore the `main` checkout. | If the build is *sound but blocked on a decision*, push the branch + open a **draft** PR linking the issue and say so — don't discard good work (see the #4-recovery precedent). |
| **Babysitter** | rebasing / fixing CI / addressing review in a PR worktree | `git rebase --abort` a conflicted rebase; discard half-applied fixes so the branch matches its last good push; **remove the worktree**. Never force-push a broken state. | Leave the PR at its last green/known commit; the `🛠️` comment records the partial progress and what's left. |
| **Triage** | refreshing the report / grooming a `help wanted` issue | Finish or revert the in-progress issue edit so no body is left half-written; still write the report (note the escalated item in it). | Keep the report and any completed groomings; only the blocked item escalates. |

---

## Hard limits (unchanged — OPERATIONS §5)
Never merge, approve, force-past a failing required check, disable branch protection, edit
`.github/workflows/*` or secrets, or **circumvent a security/permission hook** to avoid escalating.
When in doubt, escalate — that is always the safe move.
