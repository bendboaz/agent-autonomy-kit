# Changelog

All notable changes to the `agent-ops` plugin (`plugins/agent-ops/`) are documented here. This project
follows [Semantic Versioning](https://semver.org/): **patch** = bugfixes + non-breaking
`.agent-ops/config.json` schema additions, **minor** = new features, **major** = breaking changes. See
[`docs/ONBOARDING.md`](docs/ONBOARDING.md#versioning-pinning-and-upgrading) for how consuming repos pin
to and upgrade between versions.

## [1.0.0] - 2026-08-16

Initial versioned baseline. `plugins/agent-ops/.claude-plugin/plugin.json` previously had no `version`
field (SHA-versioned only via the marketplace's relative-path source); this release adds explicit
semver starting at `1.0.0` rather than `0.1.0`, since the plugin already has a live consumer
(`dnd-session-assistant`) at the time of this release.

Everything shipped up to this point is part of the `1.0.0` baseline, including:

- Three scheduled loops — **dispatch** (issues → PRs), **babysit** (keep PRs green), **triage** (groom
  the backlog) — plus an interactive **orchestrator** (`/orchestrate-agent-ops`).
- A conversation-aware **AI reviewer** (`ai_review.py`) wired via a reusable GitHub Actions workflow
  (`.github/workflows/ai-review-reusable.yml`).
- The **non-admin GitHub App** identity model: agents physically cannot merge, approve their own PRs,
  or touch branch protection — enforced by GitHub, not agent behavior (see `docs/SECURITY.md`).
- Local guardrail hooks (`hooks/block-dangerous-commands.ps1`, `hooks/block-sensitive-files.ps1`) as
  defense-in-depth alongside the GitHub-side guarantees.
- The three-layer config model — repo-agnostic engine (`plugins/agent-ops/scripts/`), per-repo config
  (`.agent-ops/`), and gitignored runtime state (`.claude/agent-state/`) — with `agent-config.ps1` as
  the loader and golden-master parity tests proving it matches the original `dnd-session-assistant`
  behavior byte-for-byte.
- `install-tasks.ps1` / `uninstall-tasks.ps1` for registering the loops as Windows scheduled tasks, and
  `cleanup.ps1` for pruning stale worktrees/locks.
