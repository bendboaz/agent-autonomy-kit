"""AI PR review: send the PR diff to Claude with a checklist, print Markdown.

Repo-agnostic. The checklist is assembled from:
  - a base checklist  (env AI_REVIEW_BASE_CHECKLIST = a file path; falls back to a built-in default);
  - the consuming repo's project checklist (env AI_REVIEW_REPO_CHECKLIST = a file path; optional);
  - an agent-ops checklist (env AI_REVIEW_AGENT_OPS_CHECKLIST) appended ONLY when the diff touches the
    repo's agent-ops path (env AI_REVIEW_AGENT_OPS_PATH, default ".agent-ops").

Role header (env AI_REVIEW_HEADER), model (env AI_REVIEW_MODEL), and max diff size
(env AI_REVIEW_MAX_DIFF_CHARS) are configurable. Reads the diff from a file (arg 1) and an optional
prior comment thread (arg 2). Driven by the kit's ai-review-reusable.yml. Needs ANTHROPIC_API_KEY.
"""

from __future__ import annotations

import os
import sys

try:
    from anthropic import Anthropic
except ImportError:  # unit tests mock this; CI/runtime installs the package
    Anthropic = None


DEFAULT_BASE = """Review the diff for:
  (a) adequate test coverage for the changed logic;
  (b) dead or deprecated code that should be removed;
  (c) correctness and maintainability consistent with the surrounding code.

Be concise and specific (file + line where useful). Group findings by severity.
If everything looks good, say so briefly rather than inventing issues."""

THREAD_PREAMBLE = """The following is the prior PR review thread. Comments are prefixed with role
headers: [Reviewing Agent] = previous automated AI review, [Implementing Agent] = automated
agent implementing changes, [Human] = the PR author/reviewer.

Take the author's and implementer's replies into account. DO NOT re-raise points that have
already been addressed or explained in the thread. Focus on the current diff and anything
that is still unresolved or new.

--- PRIOR REVIEW THREAD ---
"""


def _model() -> str:
    return os.environ.get("AI_REVIEW_MODEL", "claude-sonnet-4-6")


def _max_diff() -> int:
    return int(os.environ.get("AI_REVIEW_MAX_DIFF_CHARS", "120000"))


def _header() -> str:
    return os.environ.get("AI_REVIEW_HEADER", "\U0001f50e **[Reviewing Agent]** — automated AI review")


def _agent_ops_path() -> str:
    return os.environ.get("AI_REVIEW_AGENT_OPS_PATH", ".agent-ops")


def _read_env_file(env_var: str, default: str = "") -> str:
    path = os.environ.get(env_var)
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    return default


def _touches_path(diff: str, path: str) -> bool:
    """True if the diff adds/removes/edits any file under `path`."""
    a, b = f"--- a/{path}", f"+++ b/{path}"
    for line in diff.splitlines():
        if line.startswith(a) or line.startswith(b):
            return True
    return False


def build_checklist(diff: str) -> str:
    parts = [_read_env_file("AI_REVIEW_BASE_CHECKLIST", DEFAULT_BASE)]
    repo = _read_env_file("AI_REVIEW_REPO_CHECKLIST", "")
    if repo:
        parts.append("\nProject-specific checks for this repo:\n" + repo)
    if _touches_path(diff, _agent_ops_path()):
        ops = _read_env_file("AI_REVIEW_AGENT_OPS_CHECKLIST", "")
        if ops:
            parts.append("\n" + ops)
    return "\n".join(parts)


def main() -> None:
    if len(sys.argv) < 2:
        print("_AI review: no diff file provided._")
        return
    with open(sys.argv[1], encoding="utf-8") as f:
        diff = f.read()
    if not diff.strip():
        print("_AI review: empty diff, nothing to review._")
        return

    prior_thread = ""
    if len(sys.argv) >= 3:
        try:
            with open(sys.argv[2], encoding="utf-8") as f:
                prior_thread = f.read().strip()
        except FileNotFoundError:
            pass  # first review — no prior thread yet

    max_chars = _max_diff()
    truncated = len(diff) > max_chars
    if truncated:
        cap = diff.rfind("\n", 0, max_chars)
        diff = diff[: cap if cap != -1 else max_chars]

    checklist = build_checklist(diff)
    if prior_thread:
        prompt = (
            f"{checklist}\n\n{THREAD_PREAMBLE}{prior_thread}\n--- END OF PRIOR THREAD ---\n\n"
            f"Diff:\n```diff\n{diff}\n```"
        )
    else:
        prompt = f"{checklist}\n\nDiff:\n```diff\n{diff}\n```"

    if Anthropic is None:
        print("_AI review: the `anthropic` package is not installed._")
        return
    client = Anthropic()
    msg = client.messages.create(
        model=_model(),
        max_tokens=1500,
        messages=[{"role": "user", "content": prompt}],
    )
    text = "".join(b.text for b in msg.content if getattr(b, "type", None) == "text")
    review_body = text or "_AI review: model returned no text._"

    print(f"{_header()}\n\n{review_body}")
    if truncated:
        print(f"\n\n_(diff truncated to {max_chars} chars for review)_")


if __name__ == "__main__":
    main()
