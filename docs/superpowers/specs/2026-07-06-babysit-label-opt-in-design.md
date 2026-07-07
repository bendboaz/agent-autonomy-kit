# Babysit label opt-in — design

**Date:** 2026-07-06
**Status:** approved, implemented on `feat/babysit-label-opt-in`

## Problem

`babysit-prs`'s hard guardrail scopes it to PRs whose head branch matches `.agent-ops/config.json`'s
`branchPrefix` (`claude/agent/issue-*` — the autonomous dispatch lane), and explicitly never touches an
interactive `claude/...` branch. This correctly excluded PR #9
(`bendboaz/agent-autonomy-kit`, branch `docs/playbook-review-guidance`), an interactively-authored PR
with real AI-review feedback that would otherwise benefit from a babysitter round.

Widening this by loosening `branchPrefix` itself was rejected: that value is also load-bearing for
dispatch's concurrency-cap counting ([common.ps1:146](../../../plugins/agent-ops/scripts/common.ps1))
and `Get-LinkedPRForIssue`'s exact `<prefix><issue-number>` matching
([common.ps1:82](../../../plugins/agent-ops/scripts/common.ps1)) — loosening it would also loosen the
dispatch cap and break issue-linking, not just widen babysit's scope.

## Design

Babysit's scope becomes: a PR is eligible if its branch matches `branchPrefix` **or** it carries an
opt-in label (`labels.babysit`, default `babysit`) that a human applies explicitly, per PR. Dispatch's
concurrency cap and issue-linking remain exclusively branch-prefix-based — unchanged.

- **Config:** `labels.babysit` is optional (not run through `Assert-AgentKey`); absent → defaults to
  `"babysit"` in the loader. No existing consuming repo's committed `config.json` needs to change.
- **Engine:** new pure predicate `Test-PRBabysitEligible` in `common.ps1` (mirrors the existing
  `Get-PRNeedsAttention` pure-classifier pattern) — `(branchPrefix match) OR (babysit label) AND (NOT
  needsAttention)`. `Get-PRsNeedingAttention`'s coarse filter now calls it.
- **Docs:** `SKILL.md` (babysit-prs), `BABYSIT.md`, and `OPERATIONS.md` (the shared-contract authority)
  updated in lockstep so the guardrail wording is consistent everywhere it's stated.
- **Tests:** new Pester cases for `Test-PRBabysitEligible` (branch-only, label-only, neither,
  needs-attention overriding either path) plus a config-loader case asserting the default applies when
  the key is absent from the existing `dnd` golden-master fixture — proving back-compat without
  modifying that fixture.

## Rollout

Ships as an additive, backward-compatible change. Onboarding a PR into babysit's scope going forward
is: create the `babysit` label on the repo (once) if it doesn't exist, then apply it to the PR.
