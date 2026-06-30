# Backlog Triage — Procedure

> **Generic agent-ops playbook.** Repo-specific facts — the GitHub App / installation IDs, required CI
> checks, local-verify commands, frozen/contract files, and conventions — come from **this repo's
> `.agent-ops/config.json` and `.agent-ops/REPO-FACTS.md`**. Concrete examples below (e.g. `npm`/`tsc`,
> `frontend`/`backend`, `src/...`) are from the reference repo; always defer to this repo's files.

Triage does two things: **(A) report** — assess the open backlog and refresh a single triage-report
issue; and **(B) groom** — flesh out the issues the human has explicitly invited it to, via the
`help wanted` label. Both are bounded by the guarantee below.

**Label & destructiveness guarantee (do not skip this):**
Triage **never** applies or removes the gating labels — `ready`, `priority:*`, `blocked`,
`in-progress`, `needs-attention` — on any issue. It **never** closes, reopens, or restructures the
human's issues, and it opens no code PRs and touches no branches. The human is the sole gate on
labeling and on closing issues.

What triage **may** write to GitHub:
- its own triage-report issue (create or in-place update);
- on **`help wanted`** issues only: an expanded **issue body** and a role-headed **analysis comment**;
- **new child issues** when a `help wanted` issue's discussion asks for a split (the parent is
  *linked and left open* for the human to close — never closed by triage).

**Comments are authoritative.** Triage reads each issue's full discussion thread and treats human
comments as direction that overrides the issue body (e.g. a "let's wait for X first" comment means
the issue is *not* a `ready` candidate, no matter how complete the body is).

This procedure builds on [`OPERATIONS.md`](OPERATIONS.md). Read that file first — it is the frozen
shared contract for identity, label taxonomy, coordination, escalation, and Windows/PowerShell
gotchas. This document adds only the step-by-step triage flow; it does not redefine anything in
OPERATIONS.md.

**Runs:** locally on this machine — on demand or via a local scheduled run that opens a Claude Code
session (cloud routine deferred; see OPERATIONS.md §6). Date is supplied to each run as `$triageDate`
(format `YYYY-MM-DD`); never invent a date.

---

## 1. Preconditions

1. `GH_TOKEN` must be set to a short-lived GitHub App installation token for the configured App
   (App ID `<appId in .agent-ops/config.json>`, Installation ID `<installationId in .agent-ops/config.json>`). See OPERATIONS.md §1 for the full identity
   and KEY-ENV CONSTRAINT. The token grants read-mostly access plus issue-write for the report.

2. Local (PowerShell):
   ```powershell
   $env:GH_APP_ID = "<appId in .agent-ops/config.json>"
   $env:GH_APP_INSTALLATION_ID = "<installationId in .agent-ops/config.json>"
   $env:GH_APP_PRIVATE_KEY_PATH = "<path to the .pem, outside the repo>"
   $env:GH_TOKEN = (python the agent-ops plugin's scripts/agent_token.py)
   & $GH auth status   # must show the App, not the human
   ```

3. Cloud (GitHub Actions): token is minted by `actions/create-github-app-token` and passed as
   `GH_TOKEN`. See OPERATIONS.md §1 (CI subsection).

4. The token is short-lived (~10 min). Re-mint if a long run might exceed that window.

---

## 2. Gather open issues

Pull all open issues as JSON, excluding the triage-report issue itself (identified in step 6).

```powershell
$gh = $GH
$repo = "$RepoSlug"

# Fetch all open issues (up to 200; increase --limit if the backlog grows).
$issuesRaw = & $gh issue list `
    --repo $repo `
    --state open `
    --limit 200 `
    --json number,title,labels,body,createdAt,updatedAt

$issues = $issuesRaw | ConvertFrom-Json

# IMPORTANT — fetch each issue's comment thread PER ISSUE, never from the list call.
# `gh issue list --json comments` is UNRELIABLE: wrong counts + empty/truncated bodies
# (observed: an issue with 3 real comments came back as 1 comment with an empty body).
# `gh issue view N --json comments` returns the true thread. §3e's comment-awareness depends
# entirely on this — with the broken list data, comment-awareness silently does nothing
# (this is exactly the bug where #3 / #6 were wrongly recommended as ready).
foreach ($issue in $issues) {
    $full = & $gh issue view $issue.number --repo $repo --json comments | ConvertFrom-Json
    $issue | Add-Member -NotePropertyName comments -NotePropertyValue @($full.comments) -Force
}
```

**Find the triage-report issue number** (so it can be excluded from assessment):

```powershell
$reportIssue = $issues | Where-Object { $_.title -like "*Backlog triage*" }
$reportNumber = if ($reportIssue) { $reportIssue.number } else { $null }

# Working set: everything except the report itself
$backlog = if ($reportNumber) {
    $issues | Where-Object { $_.number -ne $reportNumber }
} else {
    $issues
}
```

**Fetch linked PRs** per issue (needed to detect in-review status and blocked relationships):

```powershell
# For each issue, check for open PRs that reference it via "Closes #N"
# gh issue view --json number gives developmentBranch; alternatively scan open PRs:
$openPRsRaw = & $gh pr list `
    --repo $repo `
    --state open `
    --limit 100 `
    --json number,title,body,headRefName,labels

$openPRs = $openPRsRaw | ConvertFrom-Json

# Build a lookup: issueNumber -> linked PR (if any)
$linkedPR = @{}
foreach ($pr in $openPRs) {
    $matches = [regex]::Matches($pr.body, "(?i)closes\s+#(\d+)")
    foreach ($m in $matches) {
        $linkedPR[[int]$m.Groups[1].Value] = $pr
    }
}
```

**Compute age** for staleness (days since `updatedAt`):

```powershell
$today = [datetime]::UtcNow
foreach ($issue in $backlog) {
    $issue | Add-Member -NotePropertyName "daysSinceUpdate" `
        -NotePropertyValue ([int]($today - [datetime]$issue.updatedAt).TotalDays) `
        -Force
}
```

---

## 3. Assess each issue

For every issue in `$backlog`, evaluate four dimensions. Record your findings; they populate the
report in step 6.

### 3a. Completeness (can a dispatcher build from this?)

A well-specified issue has all three sections that `DISPATCH.md` requires to claim and build:

- **Scope** — what is being built and why
- **Files / Owned files** — which files the agent may touch
- **Acceptance criteria** — testable conditions for done

Flag as **incomplete** if any section is missing, vague, or too short to act on without product
decisions. An incomplete issue is not a ready candidate regardless of other factors.

### 3b. Suggested priority

Assign `high` / `medium` / `low` with a one-line rationale. Signals:

- **high** — blocks other work, directly impacts a live user path, or has an explicit request from
  the human to do it soon
- **medium** — meaningful feature or fix, no hard dependency
- **low** — polish, docs, refactor, or long-tail edge case

This is a *suggestion* for the human. The human applies the `priority:*` label (see OPERATIONS.md
§2).

### 3c. Blocked-by / dependency relationships

Check issue body for explicit "depends on #N", "blocked by #N", or similar language. Also check
whether any referenced upstream issue is still open. Flag as **blocked** if a hard dependency is
unmet. (Triage proposes the `blocked` flag in the report; the human sets the label.)

### 3d. Duplicates and staleness

- **Duplicate:** two issues describe the same change. Flag both; propose which to close.
- **Stale:** not updated in more than **60 days** OR the work it describes was already merged
  (check whether a merged PR body references the issue number). Flag for human review.

### 3e. Read the discussion (comments override the body)

Read every issue's **comment thread** (fetched per-issue in §2 — the list call's comments are
unreliable). Human comments are authoritative and can change an issue's classification:

- A **"not ready" / "not yet" / "wait for X" / "let's hold on this"** comment ⇒ the issue is
  **WAITING**. It **must NOT** appear as a `ready` candidate (§4) **or** in the proposed dispatcher
  batch (§5), no matter how complete the body is. Record it under **Waiting** in the report with the
  reason + what it's waiting on. (Real examples: **#3** "wait for real-session transcripts" ⇒
  waiting-on-data; **#6** "Not ready yet, … want basic functionality up first" ⇒ waiting. Neither is a
  ready candidate.)
- A comment that **adds scope, splits, or re-prioritises** ⇒ fold it into the assessment (and, if the
  issue is `help wanted`, into the grooming in §5b).
- A comment that **resolves a blocker** ⇒ the dependency may now be clear.

When the body and a later human comment disagree, **the comment wins.** Note the divergence in the
report so the human can reconcile the body if they want (triage edits non-`help-wanted` bodies — only
the report records the discrepancy).

**Reply to comments addressed to triage.** If a human comment **directly addresses triage** — names it
("Triage — …"), asks it a question, or requests its opinion/decision — post **one** `🛠️ [Implementing
Agent]` reply that actually answers it (your assessment/opinion + recommended next step), via
`--body-file`. This applies on **any** issue, not just `help wanted` (e.g. #5's "Triage — waiting for
your opinion on this"). Replying informs the human and never applies a gating label — the human still
decides.

**Idempotency — check before you post.** The thread you need is already in hand: `$issue.comments`
(fetched per-issue in §2) carries every comment's `author.login`, `body`, and `createdAt`. Use it —
do **not** post blind. A triage-directed human comment is *answered* iff a `🛠️ [Implementing Agent]`
reply exists with `createdAt` **newer** than that human comment. Skip answered comments; reply only to
still-unanswered ones. Skeleton:

```powershell
# 1. Identify triage-directed comments. NOTE: every comment posts from the human's
#    account, so author.login can't tell human from agent — the ROLE HEADER is the only
#    signal. A trigger is a non-agent comment that names triage or asks a question.
#    These patterns are a starting filter, not the whole test — judgement still applies.
$triggers = $issue.comments | Where-Object {
    $_.body -notlike '*[Implementing Agent]*' -and          # exclude our own replies
    $_.body -notlike '*[Reviewing Agent]*' -and             # exclude CI review comments
    ($_.body -match '(?i)\btriage\b' -or $_.body -match '\?')
}
foreach ($triggerComment in $triggers) {
    # 2. Idempotency: answered iff a 🛠️ reply is NEWER than this human comment.
    $answered = $issue.comments | Where-Object {
        $_.body -like '*[Implementing Agent]*' -and
        [datetime]$_.createdAt -gt [datetime]$triggerComment.createdAt
    }
    if (-not $answered) {
        # 3. Compose the reply (role header first) and post via --body-file (ASCII, no BOM).
        $replyFile = [System.IO.Path]::GetTempFileName()
        $reply = "🛠️ **[Implementing Agent]**`n`n<your assessment + recommended next step>"
        Set-Content -Path $replyFile -Value $reply -Encoding ascii
        & $gh issue comment $issue.number --repo $repo --body-file $replyFile
        Remove-Item $replyFile
    }
}
```

### 3f. `meta` issues are context, not backlog

Issues labelled **`meta`** (tracking/status/ledger/resume issues, e.g. the triage report itself, a
review-nit ledger, a status issue) are **not** buildable work. **Exclude them from ready/priority/
blocked ranking entirely.** Instead:

- Summarise them in the report's **"Current work picture"** section (what each is tracking).
- **Recommend closing** any `meta` issue whose tracked work is fully done — in particular when every
  PR it references has **merged** (check via `gh pr view <n> --json state`). Triage *recommends* the
  close in the report; the **human closes it** (triage never closes issues).

---

## 4. Pick `ready` candidates

From the assessed backlog, select the top **3–5** issues that are:

1. **Complete** — all three sections present and unambiguous
2. **Unblocked** — no unmet hard dependencies
3. **Not a duplicate** and not stale
4. Well-sized — dispatchable in a single focused PR (not a multi-week epic)
5. **Not waiting** — no human comment asking to hold/defer it (§3e)
6. **Not `help wanted` and not `meta`** — a `help wanted` issue is still being shaped (groom it, §5b),
   a `meta` issue is not work (§3f)

Rank by suggested priority, then by issue number (older issues first within the same priority).

**Triage recommends; the human applies `ready`.** Write the candidates into the report with a
one-sentence rationale for each. Do not touch the `ready` label.

---

## 5. Propose a next dispatcher batch

From the ready candidates (or the shortlist of candidates you'd bless if the human agrees),
produce an ordered list — **priority descending, then number ascending** — of up to **5** issues
that the dispatcher should pick up once the human labels them `ready`.

Note: the dispatcher caps concurrent open PRs at **1** (OPERATIONS.md §3). A batch may be larger
(so there is a queue), but flag that the dispatcher won't exceed the cap.

---

## 5b. Groom `help wanted` issues (the mutating step)

This is the only step that writes to issues other than the report. Run it for **every open issue
labelled `help wanted`** — the human applies that label precisely to invite this. Decide **expand** vs
**split** from the issue's body + discussion (§3e). All of §5b obeys the guarantee at the top of this
file: no gating labels, no closing/restructuring, no PRs.

### When to (re-)groom — idempotency

To avoid re-grooming the same issue every nightly run, find triage's most recent analysis on the issue
(the `🛠️ [Implementing Agent]` analysis comment, or the `<!-- agent-analysis -->` body section). Groom
it **only if**:

- there is no prior analysis yet, **or**
- the latest **human** comment / human body-edit is **newer** than that analysis (the human replied and
  wants another pass).

Otherwise skip it (already groomed, awaiting the human). **Never remove the `help wanted` label** — the
human clears it when satisfied, or applies `ready` to hand the shaped issue to the dispatcher.

### Ground the analysis in the code

Before writing, **read the files the issue names** (and grep for the real call sites / types) so the
analysis is concrete. Respect contract-file rules (OPERATIONS.md §7): you may *reference* a frozen file,
but any design that changes a frozen signature must say "needs a `docs/DESIGN.md` change first."

### Mode A — Expand (default)

Append a fenced agent-analysis section to the issue **body, below the human's original text** (additive
— never delete or rewrite their words), and post a short `🛠️ [Implementing Agent]` comment pointing at
it. Begin the section with a stable marker so a re-groom can find and replace it:

```markdown
<!-- agent-analysis -->
## 🛠️ Agent analysis (triage, YYYY-MM-DD)
```

The section contains: **Opinion / recommendation** (is it worth doing, the sharpest version, any
pushback) · **Relevant files** (concrete paths + what changes) · **Design considerations** (approaches,
trade-offs, edge cases, testing seams, contract-file impact) · **Open questions for the human** (the
decisions triage must not make) · **Proposed Scope / Files / Acceptance** (a draft of the three sections
`DISPATCH.md` needs, so the human can bless `ready` with one edit once the questions are resolved).

### Mode B — Split (when the discussion asks for it)

If the body or a human comment asks to break the issue up, **create one child issue per piece**, each a
well-rounded, dispatchable issue with its own **Scope / Relevant files / Acceptance criteria**. Then
**edit the parent body** (additive) into a short tracking/epic block listing the children
(`- [ ] #childN — title`) and post a `🛠️` comment summarising the split. **Do not close the parent** —
leave that to the human. Carry the parent's context into each child and cross-link parent ↔ children.
Create children **without** gating labels; you may copy clearly-applicable descriptive labels
(`enhancement`, area labels).

### Hard limits

Never apply/remove `ready`/`priority:*`/`blocked`/`in-progress`/`needs-attention`; never close/reopen an
issue; never open a code PR or push a branch. If grooming would require any of those, write the
recommendation into the analysis and leave the action to the human.

---

## 6. Write the triage-report issue

### Find or create the report issue

The report lives in **exactly one** open issue whose canonical title is `🗂️ Backlog triage`. Match
it by the **plain substring `Backlog triage`** (not the emoji) so the lookup is robust regardless of
how the title renders; always create it *with* the emoji.

```powershell
# Reuse $issues from step 2 (the report may have been excluded from $backlog there)
$reportIssue  = $issues | Where-Object { $_.title -match "Backlog triage" }
$reportNumber = if ($reportIssue) { $reportIssue[0].number } else { $null }
```

**If the report issue already exists:** edit its body in place — do NOT create a new one.

```powershell
# Write the report body to a temp file (avoids here-string / interpolation issues — OPERATIONS.md §8)
$bodyFile = "$env:TEMP\triage-report-body.md"
Set-Content -Path $bodyFile -Value $reportBody -Encoding utf8

& $gh issue edit $reportNumber `
    --repo $repo `
    --body-file $bodyFile
```

**If no report issue exists (first run / cold start):** create it.

```powershell
& $gh issue create `
    --repo $repo `
    --title "🗂️ Backlog triage" `
    --body-file $bodyFile
```

After creating, capture the returned URL and extract the issue number from it for the
`PushNotification` link in step 7.

### Report body format

The body must open with the `🛠️ **[Implementing Agent]**` role header (OPERATIONS.md §4), followed
by a blank line, then the sections below. Date-stamp with the value of `$triageDate`.

```markdown
🛠️ **[Implementing Agent]**

_Last updated: YYYY-MM-DD_

---

## Summary

| Stat | Count |
|---|---|
| Open backlog issues (excl. `meta`) | N |
| Complete & unblocked | N |
| Incomplete | N |
| Blocked | N |
| Waiting (deferred by a human comment) | N |
| `help wanted` (groomed this run) | N |
| `meta` (tracking — context only) | N |
| Duplicate | N |
| Stale (>60 days since update) | N |

---

## Ready candidates

Issues recommended for the human to bless with `ready`:

| # | Title | Rationale |
|---|---|---|
| #N | Title | One-line rationale |
...

> ⚠️ Triage proposes; the human applies the `ready` label.

---

## Suggested priorities

| Issue | Suggested priority | Why |
|---|---|---|
| #N Title | high / medium / low | One-line reason |
...

> ⚠️ Triage proposes; the human applies `priority:*` labels.

---

## Blocked / Waiting / Duplicate / Stale flags

**Blocked**
- #N — blocked by #M (still open)

**Waiting** (deferred by a human comment — §3e)
- #N — held per comment: <reason / what it's waiting on>

**Duplicate**
- #N duplicates #M — recommend closing #N

**Stale**
- #N — last updated DD days ago; may be obsoleted by <merged work or reason>

_(If any section is empty, write "None detected.")_

---

## Current work picture (`meta` issues)

`meta` issues are tracking/coordination, not backlog. Recommend closing any whose work is fully done.

| # | Tracking | Recommend |
|---|---|---|
| #N | what it tracks | keep / **close** (all referenced PRs merged) |

---

## Help-wanted grooming (this run)

Issues groomed this run (§5b). Each `help wanted` issue is expanded or split; the human still owns
`ready`.

| # | Action | Notes |
|---|---|---|
| #N | expanded / split → #a, #b, #c / skipped (already groomed) | one line |

---

## Proposed next dispatcher batch

Ordered shortlist for the dispatcher once the human blesses them. Dispatcher cap: 1 concurrent PR.

1. #N — Title (priority: high)
2. #N — Title (priority: high)
3. #N — Title (priority: medium)
...

---

_No gating labels were applied or removed; no issues were closed; no PRs were opened. `help wanted`
issues may have been expanded/split (§5b) — see "Help-wanted grooming" above._
```

---

## 7. Notify

After the report is written (or updated), send a `PushNotification` with:

- **Title:** `Backlog triage complete — YYYY-MM-DD`
- **Body:** one line summarising counts and the top ready candidate, e.g.:
  `12 open issues: 4 complete/unblocked, 3 ready candidates. Top pick: #42 Add phonetic matching. Report: <URL>`

Do NOT send a notification for routine intermediate steps — only once the report is posted.
If triage itself hits a boundary (an error it can't handle, a grooming action it can't complete),
escalate via the shared **[`ESCALATION.md`](ESCALATION.md)** runbook (OPERATIONS.md §5 for *when*) —
stabilize the in-flight issue edit, still write the report, then `needs-attention` + one comment + one
notification. Do not silently swallow failures.

---

## 8. Cold-start note (first run)

On the first run the backlog is unlabeled — no `ready`, no `priority:*`, no `blocked`. Triage
still runs the full assessment above. The report does the initial pass over all open issues,
proposing priorities and ready candidates. This is intentional: the human reviews the report and
applies labels to bootstrap the labeling state. Subsequent runs will have a richer starting
point.

---

## Operational notes

- **Do not** apply or remove the **gating labels** (`ready` / `priority:*` / `blocked` /
  `in-progress` / `needs-attention`) on any issue — OPERATIONS.md §2/§3 assign their ownership to the
  human / dispatcher. (Triage *may* create child issues during a split and copy clearly-applicable
  **descriptive** labels onto them, per §5b — never gating labels.)
- **Do not** close, reopen, or restructure any issue. Triage *recommends* closes (e.g. done `meta`
  issues) in the report; the human acts on them.
- **Do not** open code PRs, create branches, or push commits.
- **Re-mint the token** if the run takes longer than ~10 minutes. See OPERATIONS.md §1.
- **Windows / PowerShell gotchas:** see OPERATIONS.md §8. In particular: use `--body-file` not
  inline `--body` for multiline content; avoid `2>&1` on `gh`/`git`; no `&&` — use `;` or
  `if ($?) { ... }`.
- **gh path:** `$GH` (not always on `PATH`). Assign to `$gh` at
  the top of the script.
