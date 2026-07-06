# DISPATCH — Issue → PR procedure

> **Generic agent-ops playbook.** Repo-specific facts — the GitHub App / installation IDs, required CI
> checks, local-verify commands, frozen/contract files, and conventions — come from **this repo's
> `.agent-ops/config.json` and `.agent-ops/REPO-FACTS.md`**. Concrete examples below (e.g. `npm`/`tsc`,
> `frontend`/`backend`, `src/...`) are from the reference repo; always defer to this repo's files.

The dispatcher is the autonomous loop that turns `ready` GitHub issues into pull requests. It runs as
a key-env'd local session on this machine — on-demand, or via a local scheduled run (cloud routine
deferred; see OPERATIONS.md §6). See **`OPERATIONS.md`** for the shared rules this procedure depends on: identity &
token (§1), label taxonomy & ownership (§2), coordination protocol (§3), role headers (§4),
escalation policy (§5), run model (§6), repo facts (§7), and Windows/PowerShell gotchas (§8).

This file covers the *step-by-step procedure only* — it does not redefine any of those rules.

---

## 0. Quick-reference: modes

| Mode | Effect |
|---|---|
| Normal run | Full loop: select → gate → claim → build → verify → PR |
| `--dry-run` | Read-only: select + print only. **Safe first action.** |

Always run `--dry-run` first when setting up or debugging. See [Step 9](#9-dry-run-mode).

---

## 1. Preconditions

The dispatcher acts as the **the configured App GitHub App**, not as the human. `GH_TOKEN` must be an
App installation token minted by `agent_token.py` (see OPERATIONS.md §1).

**Before doing anything that writes (labels, branches, PRs):**

```powershell
# Set App env vars (outside the repo — never in .env inside the repo)
$env:GH_APP_ID             = "<appId in .agent-ops/config.json>"
$env:GH_APP_INSTALLATION_ID = "<installationId in .agent-ops/config.json>"
$env:GH_APP_PRIVATE_KEY_PATH = "<absolute path to .pem, outside the repo>"

# Mint a short-lived token
$env:GH_TOKEN = (python the agent-ops plugin's scripts/agent_token.py)

# VERIFY: output must show the App ("the App bot (…[bot])"), NOT the human account.
# If it shows the human, stop — the env is wrong.
& $GH auth status
```

The token expires in ~10 minutes. For runs covering multiple issues, re-mint between issues:

```powershell
$env:GH_TOKEN = (python the agent-ops plugin's scripts/agent_token.py)
```

The backend venv has the required deps (`pyjwt[crypto]`, `requests`). Activate it first if
`python` does not resolve to that environment:

```powershell
# Example — adjust path to wherever the venv lives
& "the repo root\backend\.venv\Scripts\Activate.ps1"
```

---

## 1b. Cleanup first (self-healing)

Before selecting work, prune finished branches/worktrees from prior runs so stale state never
accumulates (see OPERATIONS.md §9). Safe + idempotent — it only removes branches/worktrees whose PR
is merged/closed:

```powershell
pwsh the agent-ops plugin's scripts/cleanup.ps1        # or: -DryRun to preview
```

---

## 2. Select work

### 2.1 Fetch open issues and filter to dispatchable

An issue is **dispatchable** iff (per OPERATIONS.md §2):
- Has label `ready`
- Does NOT have label `blocked`
- Does NOT have label `in-progress`
- Has no open linked PR (see §2.2 below)

```powershell
$gh = $GH
$repo = "$RepoSlug"

# Fetch all open issues with ready label (excludes blocked/in-progress via filter below)
$issues = & $gh issue list `
    --repo $repo `
    --state open `
    --label "ready" `
    --json number,title,labels,body `
    --limit 100 | ConvertFrom-Json

# Filter out blocked and in-progress
$candidates = $issues | Where-Object {
    $labelNames = $_.labels | ForEach-Object { $_.name }
    ($labelNames -notcontains "blocked") -and ($labelNames -notcontains "in-progress")
}
```

### 2.2 Detect open linked PRs

An issue `N` has an open linked PR if there exists an open PR whose **body contains `#N`** or
whose **head branch is `claude/agent/issue-N`**.

```powershell
# Fetch all open PRs on agent branches
$openAgentPRs = & $gh pr list `
    --repo $repo `
    --state open `
    --json number,headRefName,body `
    --limit 100 | ConvertFrom-Json

# For each candidate, check for an existing linked PR
$dispatchable = $candidates | Where-Object {
    $n = $_.number
    $hasLinkedPR = $openAgentPRs | Where-Object {
        ($_.headRefName -eq "claude/agent/issue-$n") -or
        ($_.body -match "(Closes|Fixes|Resolves)\s+#$n\b")
    }
    -not $hasLinkedPR
}
```

### 2.3 Order by priority then issue number

Priority order: `priority: high` > `priority: medium` > `priority: low` > (no priority label).

```powershell
function Get-PriorityRank($issue) {
    $labelNames = $issue.labels | ForEach-Object { $_.name }
    if ($labelNames -contains "priority: high")   { return 0 }
    if ($labelNames -contains "priority: medium") { return 1 }
    if ($labelNames -contains "priority: low")    { return 2 }
    return 3
}

$ordered = $dispatchable | Sort-Object -Property @(
    @{ Expression = { Get-PriorityRank $_ }; Ascending = $true },
    @{ Expression = { $_.number };            Ascending = $true }
)
```

---

## 3. Concurrency gate

Count open `claude/agent/issue-*` PRs. If the count is at or above the cap (default **1**), stop.
Do not claim any new issue.

```powershell
$cap = 1

$openAgentPRCount = ($openAgentPRs | Where-Object {
    $_.headRefName -like "claude/agent/issue-*"
}).Count

if ($openAgentPRCount -ge $cap) {
    Write-Host "Concurrency cap reached ($openAgentPRCount / $cap open agent PRs). Stopping."
    exit 0
}

# Build several issues in parallel this run, up to the available slots.
$slots = $cap - $openAgentPRCount
$batch = @($ordered | Select-Object -First $slots)
```

---

## 3b. Independence filter — what to parallelize

Build only a **mutually-independent** subset of `$batch` in parallel. Two issues are independent iff
the files they will touch are **disjoint** — parallel PRs that edit the same files conflict on merge
(and risk incoherent changes). For each candidate, read its declared scope
(`gh issue view N --json body` → the **Relevant files** / **Scope** section) and extract the paths it
will change. Greedily, highest-priority first: seed the selected set with the top candidate; add each
later candidate only if its file set is **disjoint** from the union of already-selected sets **and**
from the files of any in-flight agent PR. If a candidate declares no usable file list, or the overlap
is uncertain, **leave it out** of this run's parallel batch — it becomes a top, solo pick on a later
run. This independence judgement is the single non-deterministic step; priority order, the cap, and
file extraction are deterministic.

```powershell
# Greedy independence filter. $fileSet[N] = repo-relative paths issue N declares it will touch.
# (The dispatcher applies judgement when an issue's file list is fuzzy; when in doubt, exclude.)
$selected      = @()
$claimedFiles  = @()   # union of files for already-selected issues (+ any in-flight agent PRs)
foreach ($issue in $batch) {
    $files = Get-IssueFiles $issue        # parse "Relevant files"/"Scope" from the issue body
    if ($selected.Count -eq 0) { $selected += $issue; $claimedFiles += $files; continue }
    $overlaps = $files | Where-Object { $claimedFiles -contains $_ }
    if ($files.Count -gt 0 -and -not $overlaps) {
        $selected += $issue; $claimedFiles += $files   # disjoint -> safe to build in parallel
    }
    # else: overlapping or unknown scope -> defer to a later run
}
$toDispatch = $selected                    # >= 1 issue
```

The issues in `$toDispatch` are independent, so Steps 4–7 run for them **in parallel** — each gets its
own worktree + branch and its own implementing subagent, spawned concurrently. A single run thus opens
up to `$slots` PRs, but only for non-conflicting issues.

---

## 4. Claim

**Set `in-progress` on the issue BEFORE creating the branch.** This is the lock (OPERATIONS.md §3
rule 5). Only the dispatcher writes `in-progress`; no other loop touches it.

```powershell
foreach ($issue in $toDispatch) {
    $n = $issue.number

    # Re-mint token before each issue to avoid expiry on long runs
    $env:GH_TOKEN = (python the agent-ops plugin's scripts/agent_token.py)

    & $gh issue edit $n `
        --repo $repo `
        --add-label "in-progress"

    if (-not $?) {
        Write-Host "Failed to set in-progress on #$n — skipping."
        continue
    }

    # Proceed to Step 5 for this issue ...
}
```

---

## 5. Build in isolation

### 5.1 Create a git worktree

```powershell
$branch = "claude/agent/issue-$n"
$repoRoot = "the repo root"
$worktreePath = "the configured worktree base\issue-$n"

# Fetch latest main
git -C $repoRoot fetch origin main

# Create worktree on a new branch off origin/main
git -C $repoRoot worktree add $worktreePath -b $branch origin/main

if (-not $?) {
    Write-Host "Worktree creation failed for #$n — clearing in-progress and skipping."
    & $gh issue edit $n --repo $repo --remove-label "in-progress"
    continue
}
```

### 5.2 Spawn an implementing subagent

Spawn a **Sonnet** subagent (never Haiku for implementing work; never Opus). The subagent prompt
must be self-contained and include:

- Working directory: `$worktreePath` (absolute Windows path)
- Use the **PowerShell tool** exclusively; never Bash
- Read the issue body from `gh issue view $n --repo $repo --json body,title` for Scope/Files/Acceptance
- Implement strictly from the issue's Scope, owned Files, and Acceptance Criteria
- **Contract files are READ-ONLY** — see OPERATIONS.md §7 *Contract files (frozen)* for the exact,
  authoritative definition (fully-frozen files, the `loader.ts` public-interface nuance, and the
  test-file carve-out). The subagent must follow that definition, not a looser/narrower paraphrase.
- **`.agent-ops/**` is orchestrator-only** (OPERATIONS.md §3 rule 6) — never edit the agent
  playbook. If the issue's fix would require changing it, STOP and have the dispatcher escalate the
  issue (§8) instead of building it. (The deny-hook blocks such edits under `AGENT_LOOP=1` anyway.)
- Follow all conventions in the repo `CLAUDE.md` (Tailwind theme CSS vars, no `any`, relative
  imports, mobile-first)
- Run verification (Step 6) before reporting done
- Stage and commit all changes on branch `$branch`; propose the commit message for confirmation

The subagent must NOT open a PR itself — the dispatcher loop (Step 7) does that.

---

## 6. Verify before PR

The subagent (or the dispatcher after the subagent completes) must run all required checks locally
before the PR is opened. All must pass.

```powershell
Set-Location $worktreePath

# Install deps (if package-lock changed)
npm ci

# Frontend checks (always required)
npx tsc --noEmit
npm run build
npm test

# Backend checks (run if backend/ files were changed)
# Activate the backend venv first, then:
Set-Location "$worktreePath\backend"
pytest
Set-Location $worktreePath
```

If any check fails with a **mechanical error** (missing import, type mismatch the subagent caused),
the subagent should fix it and re-verify. If it fails in a way that **needs real logic, product
decision, or a contract file change**, go to [Step 8 (Failure path)](#8-failure--ambiguity-path).

---

## 7. Open PR, then clear `in-progress`

**Order matters:** push the branch and open the PR first; clear `in-progress` second. The open PR
now signals "in-review" (per OPERATIONS.md §2 — there is no `in-review` label).

### 7.1 Push the branch

```powershell
git -C $worktreePath push origin $branch
```

### 7.2 Write the PR body to a temp file

The PR body must start with the `🛠️ **[Implementing Agent]**` role header (OPERATIONS.md §4),
then a blank line, then a summary of what was done and how it was verified. It must contain
`Closes #N` so GitHub links the issue.

Always use `--body-file`, not a here-string or `--body`, to avoid PowerShell escaping issues
(OPERATIONS.md §8).

```powershell
$prBodyPath = [System.IO.Path]::GetTempFileName() + ".md"

@"
🛠️ **[Implementing Agent]**

Closes #$n

## What was done
<!-- subagent fills this in: brief description of the implementation -->

## How it was verified
- `npx tsc --noEmit` passed
- `npm run build` passed
- `npm test` passed
<!-- add: `pytest` passed — if backend changes were included -->
"@ | Set-Content -Path $prBodyPath -Encoding utf8
```

### 7.3 Open the PR

Always assign the repo owner as reviewer (resolve dynamically — no hardcoded logins in the engine).
"Assign reviewer" means the GitHub `--reviewer` flag, **not** a confirmation step before opening the PR.

```powershell
$owner = (& $gh repo view $repo --json owner --jq '.owner.login')
& $gh pr create `
    --repo $repo `
    --head $branch `
    --base main `
    --title "$(& $gh issue view $n --repo $repo --json title --jq '.title') (closes #$n)" `
    --body-file $prBodyPath `
    --reviewer $owner

Remove-Item $prBodyPath -ErrorAction SilentlyContinue
```

### 7.4 Clear `in-progress`

Only after the PR is open (so that no other dispatcher run can double-claim while the PR is
opening).

```powershell
& $gh issue edit $n `
    --repo $repo `
    --remove-label "in-progress"
```

### 7.5 Clean up the worktree

```powershell
git -C $repoRoot worktree remove $worktreePath --force
```

**Hard rules (per OPERATIONS.md §5):** never merge, never approve, never force-past a failing
check, never touch `.github/workflows/*` or secrets.

---

## 8. Failure / ambiguity path

This is the dispatcher's instance of the shared **[`ESCALATION.md`](ESCALATION.md)** runbook — follow
its order (stop → stabilize the halted build → finish the batch's independent issues → gather context →
offer alternatives → alert → leave a resumable trail). The steps below are its dispatcher-specific form.

Use this path when:
- Verification fails in a way needing real logic (not a mechanical fix)
- The issue is ambiguous or under-specified (missing scope, conflicting requirements)
- Implementation would require editing a **contract file** (per OPERATIONS.md §7 *Contract files
  (frozen)*)
- Anything else at the boundary of autonomous capability

### 8.1 Open a draft PR (if there is partial work to preserve)

```powershell
& $gh pr create `
    --repo $repo `
    --head $branch `
    --base main `
    --draft `
    --title "[DRAFT] Issue #$n — blocked, needs attention" `
    --body-file $prBodyPath   # body explains the blocker
```

If there is no useful partial work, skip the draft PR.

### 8.2 Add `needs-attention` and post a comment

```powershell
& $gh issue edit $n `
    --repo $repo `
    --add-label "needs-attention"

$commentPath = [System.IO.Path]::GetTempFileName() + ".md"

@"
🛠️ **[Implementing Agent]**

Blocked on issue #$n — needs human attention.

**Reason:** <!-- fill in: ambiguity / contract file needed / verification failure -->

**Details:**
<!-- describe exactly what would be needed to proceed -->
"@ | Set-Content -Path $commentPath -Encoding utf8

& $gh issue comment $n `
    --repo $repo `
    --body-file $commentPath

Remove-Item $commentPath -ErrorAction SilentlyContinue
```

### 8.3 Send a PushNotification

Send a `PushNotification` with a one-line summary and a link to the issue (or draft PR).
Escalation format per OPERATIONS.md §5:

```
[Dispatcher] Issue #N blocked — <one-line reason>. <URL>
```

### 8.4 Clear `in-progress` and move on

```powershell
& $gh issue edit $n `
    --repo $repo `
    --remove-label "in-progress"
```

Clean up the worktree and continue to the next issue in the ordered list.

---

## 9. `--dry-run` mode

In dry-run mode, the dispatcher executes steps 2 and 3 (select + gate) only and **prints** the
ordered list of issues it would dispatch. It makes **zero writes**: no label changes, no branches,
no PRs.

This is the **safe validation entry point** — always use it first when setting up or debugging.

```powershell
$gh = $GH
$repo = "$RepoSlug"

# --- steps 2.1–2.3: fetch, filter, order (read-only) ---
# [same PowerShell as Steps 2 and 3 above, up through $toDispatch]

Write-Host "=== DRY RUN: would dispatch $($toDispatch.Count) issue(s) ==="
Write-Host "Open agent PRs: $openAgentPRCount / $cap (cap)"
Write-Host ""
foreach ($issue in $toDispatch) {
    $pri = (Get-PriorityRank $issue)
    $priLabel = @("high","medium","low","none")[$pri]
    Write-Host "  #$($issue.number) [$priLabel] $($issue.title)"
}
Write-Host ""
Write-Host "No writes made. Re-run without --dry-run to dispatch."
```

---

## 10. Full PowerShell snippet index

| Step | Key commands |
|---|---|
| Mint token | `$env:GH_TOKEN = (python the agent-ops plugin's scripts/agent_token.py)` |
| Verify identity | `& $GH auth status` |
| Fetch issues | `gh issue list --repo ... --label ready --json ... \| ConvertFrom-Json` |
| Fetch open PRs | `gh pr list --repo ... --state open --json headRefName,body \| ConvertFrom-Json` |
| Add label | `gh issue edit N --repo ... --add-label "in-progress"` |
| Remove label | `gh issue edit N --repo ... --remove-label "in-progress"` |
| Create worktree | `git worktree add <path> -b claude/agent/issue-N origin/main` |
| Push branch | `git push origin claude/agent/issue-N` |
| Open PR | `gh pr create --head claude/agent/issue-N --base main --body-file <path> --reviewer <owner>` |
| Open draft PR | `gh pr create --draft ...` |
| Post issue comment | `gh issue comment N --repo ... --body-file <path>` |
| Remove worktree | `git worktree remove <path> --force` |

All `gh` commands use `$GH` explicitly (not relying on PATH).
Never use `--jq` with `\(...)` interpolation or here-strings for bodies — see OPERATIONS.md §8.
No `&&` chaining — use `;` or `if ($?) { ... }`.
