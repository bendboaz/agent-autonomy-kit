# Onboarding a repo

How to put a repo under agent-ops. Windows / PowerShell.

## Versioning, pinning, and upgrading

The plugin is versioned via `"version"` in `plugins/agent-ops/.claude-plugin/plugin.json` (currently
`1.0.0`), following semver:

- **patch** (`1.0.x`) — bugfixes, and non-breaking additions to the `.agent-ops/config.json` schema
  (a consuming repo's existing config keeps working; a new optional field showed up).
- **minor** (`1.x.0`) — new features (new skill, new loop capability, new optional config knob) that
  don't break an existing consumer.
- **major** (`x.0.0`) — breaking changes (a required config field changes shape/meaning, a script's CLI
  contract changes, a loop's authorization behavior changes).

### Why there's no separate version in `marketplace.json`

The marketplace catalog (`.claude-plugin/marketplace.json`) lists the plugin via a **relative path**
source (`"./plugins/agent-ops"`), not a `github`/`url` source — the plugin lives in this same repo.
Claude Code's version-resolution order is: `plugin.json`'s `version` field first, then the marketplace
entry's `version`, then (for git-hosted relative-path sources) the marketplace repo's own commit SHA.
Because `plugin.json` already declares a version, it is always authoritative — Claude Code silently
ignores a `version` set on the marketplace entry, so setting one there would just be a footgun (a stale
second copy nobody notices drifting). We deliberately leave the marketplace entry without a `version`
field and treat `plugin.json`'s field as the single source of truth. `.claude-plugin/marketplace.json`
itself keeps no version pin and continues to track whatever commit the marketplace was added/updated
at (normally `main`'s tip) — see below for how a consumer pins that instead.

### Pinning a consuming repo to a specific plugin version

Adding the marketplace with `claude plugin marketplace add bendboaz/agent-autonomy-kit` (or the `/plugin
marketplace add` slash command) tracks the repo's **default branch** (`main`) and follows it on every
`/plugin marketplace update` / background auto-update — you get whatever `plugin.json` version is at
`main`'s tip at update time.

To **pin** to a specific released version instead, register the marketplace via `extraKnownMarketplaces`
in `.claude/settings.json` (project or user scope) with an explicit `ref` (a git tag) or `sha`:

```json
{
  "extraKnownMarketplaces": {
    "boaz-agent-ops": {
      "source": {
        "source": "github",
        "repo": "bendboaz/agent-autonomy-kit",
        "ref": "v1.0.0"
      }
    }
  }
}
```

This clones the marketplace repo (and therefore the relative-path `agent-ops` plugin inside it) at that
tag, so `plugin.json`'s `version` field there is what gets installed, and it won't move until you bump
`ref` yourself. Release tags (`v<version>`, e.g. `v1.0.0`) are cut manually today at merge time — see
`CHANGELOG.md` at the repo root for what's shipped at each version. Automating tag creation on release is
tracked separately (a sibling issue that touches `.github/workflows/**`, out of scope here).

### Upgrading

1. Check `CHANGELOG.md` for what changed between your pinned version and the target version — a **major**
   bump means re-reading `.agent-ops/config.json` against the new template before upgrading.
2. Bump the `ref`/`sha` in `extraKnownMarketplaces` (if pinned) or run `/plugin marketplace update`
   (if tracking `main`), then `claude plugin update agent-ops@boaz-agent-ops`.
3. Re-run the **Verify** steps below to confirm the loops still behave as expected.

## Preconditions (hard)

1. **The repo is PUBLIC with branch protection on `main`** (PR + ≥1 approval, no self-approve, required
   checks, `enforce_admins=false`). This is what makes the App unable to merge — see [SECURITY.md](SECURITY.md).
   On a GH plan where private repos can't have branch protection, the repo must be public.
2. **A GitHub App** (non-admin: contents + PRs + issues write, no admin/merge) is **installed on the repo**.
   You can reuse one App across repos — each repo just needs its own Installation ID.
3. The App's **private key `.pem`** lives outside any repo, at the path in the user-scope env var
   `GH_APP_PRIVATE_KEY_PATH`.
4. `ANTHROPIC_API_KEY` is added as a **repo secret** (for the AI reviewer).

## Steps

### 1. Install the plugin (once per machine)
```powershell
claude plugin marketplace add bendboaz/agent-autonomy-kit
claude plugin install agent-ops@boaz-agent-ops
# enable it for this repo (per-project, so the guardrail hook scopes to opted-in repos)
```

### 2. Add `.agent-ops/` to the repo
Copy the templates from the plugin (`plugins/agent-ops/templates/`) and fill them in:
```
<repo>/.agent-ops/
├─ config.json          # from config.example.json — repoSlug, appId, installationId, appBotLogin,
│                       #   branchPrefix, defaultCap, labels{}, roleHeaders{}, verify{}, agentOpsPath
├─ config.local.json    # from config.local.example.json — GITIGNORED machine paths (worktreeBase, venvScripts, ghPath)
├─ REPO-FACTS.md        # from REPO-FACTS.example.md — required checks, local verify, contract files, conventions
└─ REVIEW-CHECKLIST.md  # from REVIEW-CHECKLIST.example.md — the project's AI-review checklist
```
Add `**/config.local.json`, `**/agent-state/`, `*.backoff`, and `*-lock-*.json` to the repo's `.gitignore`.

### 3. Wire the AI reviewer
Copy `templates/ai-review.caller.yml` to `<repo>/.github/workflows/ai-review.yml`; set its
`paths:` filter to your source dirs. Confirm `ANTHROPIC_API_KEY` is a repo secret.

### 4. Enable auto permission mode for the loops (once per machine)
The `run-{dispatch,babysit,triage}.ps1` wrappers launch `claude -p` with `--permission-mode auto`, so
headless runs get routed through Claude Code's background safety classifier instead of either
(a) prompting for approval with no TTY to answer it, or (b) needing a hand-maintained static allowlist.
Requires Claude Code v2.1.83+ and Sonnet 4.6+/Opus 4.6+ (see [Permission modes](https://code.claude.com/docs/en/permission-modes#eliminate-prompts-with-auto-mode)).

Merge `plugins/agent-ops/templates/autoMode.settings.example.json` into your **user-scope**
`~/.claude/settings.json` (project-level `autoMode` is intentionally ignored by Claude Code, so this
can't be committed into the repo). Fill in the placeholders per repo you onboard. The `environment`
block tells the classifier which repos/services are trusted (cuts down false-positive blocks); the
`soft_deny` block encodes the loops' own authorization limits (no autonomous merge/self-approve/label
changes) as defense-in-depth alongside the non-admin GitHub App identity — `soft_deny` still yields to
an explicit human instruction in an interactive session, it only holds the line when nothing prompted it.

### 5. Register the loops (run in a real terminal, not via Claude)
```powershell
# From a PowerShell terminal (PS 5.1 or PS 7 both work):
.\<plugin>\scripts\install-tasks.ps1 -RepoRoot <repo root> -WhatIf   # preview
.\<plugin>\scripts\install-tasks.ps1 -RepoRoot <repo root>           # register
```
This creates `agentops-<repo>-{dispatch,babysit,triage}` scheduled tasks. Remove with
`.\<plugin>\scripts\uninstall-tasks.ps1 -RepoRoot <repo root>`.

## Verify

1. **Auth:** from the repo root, `$env:AGENT_OPS_REPO = (Get-Location).Path`, dot-source the plugin's
   `scripts/common.ps1`, run `Initialize-AgentAuth` → `gh auth status` shows the App bot, not you.
2. **Dispatch dry run:** `/dispatch-ready-issues` and follow DISPATCH.md's dry-run step — it prints the
   ordered selection with **zero** writes.
3. **AI review:** open a test PR (or `workflow_dispatch` the ai-review workflow with a PR number) → a
   `[Reviewing Agent]` comment appears.
4. **Loops:** let the scheduled tasks fire once, or run a wrapper manually:
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <plugin>\scripts\run-dispatch.ps1 -RepoRoot <repo root>`.

## Day-2

Supervise with `/orchestrate-agent-ops` (the HEALTHCHECK). Change loop *behavior* in the kit (the
plugin); change repo *facts* in the repo's `.agent-ops/**` via a PR. Never let a loop edit its own rules.
