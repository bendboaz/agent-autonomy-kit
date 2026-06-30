"""Unit tests for ai_review: checklist assembly, path detection, truncation, emission, thread-awareness.

The Anthropic client is mocked, so these run with no network and no API key (and even with the
`anthropic` package absent — ai_review guards the import and the tests patch ai_review.Anthropic).
"""

from __future__ import annotations

import sys
from unittest import mock

import ai_review


def test_touches_path():
    diff = "--- a/.agent-ops/config.json\n+++ b/.agent-ops/config.json\n@@ -1 +1 @@\n-x\n+y\n"
    assert ai_review._touches_path(diff, ".agent-ops")
    assert not ai_review._touches_path("--- a/src/foo.ts\n+++ b/src/foo.ts\n", ".agent-ops")


def test_build_checklist_base_only(monkeypatch):
    monkeypatch.delenv("AI_REVIEW_BASE_CHECKLIST", raising=False)
    monkeypatch.delenv("AI_REVIEW_REPO_CHECKLIST", raising=False)
    c = ai_review.build_checklist("--- a/src/x\n+++ b/src/x\n")
    assert "test coverage" in c
    assert "Label ownership" not in c  # agent-ops section not appended for a src-only diff


def test_build_checklist_appends_repo_checklist(tmp_path, monkeypatch):
    p = tmp_path / "REVIEW-CHECKLIST.md"
    p.write_text("FROZEN: src/contract.ts", encoding="utf-8")
    monkeypatch.setenv("AI_REVIEW_REPO_CHECKLIST", str(p))
    c = ai_review.build_checklist("--- a/src/x\n")
    assert "FROZEN: src/contract.ts" in c


def test_build_checklist_appends_agent_ops_only_when_touched(tmp_path, monkeypatch):
    ops = tmp_path / "ops.md"
    ops.write_text("Label ownership rules apply", encoding="utf-8")
    monkeypatch.setenv("AI_REVIEW_AGENT_OPS_CHECKLIST", str(ops))
    monkeypatch.setenv("AI_REVIEW_AGENT_OPS_PATH", ".agent-ops")

    touched = "--- a/.agent-ops/config.json\n+++ b/.agent-ops/config.json\n"
    assert "Label ownership rules apply" in ai_review.build_checklist(touched)

    untouched = "--- a/src/x\n+++ b/src/x\n"
    assert "Label ownership rules apply" not in ai_review.build_checklist(untouched)


def _fake_client(captured):
    block = mock.Mock()
    block.type = "text"
    block.text = "LGTM - no issues."
    fake_msg = mock.Mock()
    fake_msg.content = [block]
    client = mock.Mock()

    def _create(**kwargs):
        captured["prompt"] = kwargs["messages"][0]["content"]
        captured["model"] = kwargs["model"]
        return fake_msg

    client.messages.create.side_effect = _create
    return client


def test_main_emits_header_and_uses_thread(tmp_path, monkeypatch, capsys):
    diff = tmp_path / "pr.diff"
    diff.write_text("--- a/src/x\n+++ b/src/x\n+code\n", encoding="utf-8")
    thread = tmp_path / "thread.txt"
    thread.write_text("[Human] please fix the thing", encoding="utf-8")
    monkeypatch.setenv("AI_REVIEW_HEADER", "ROLE-HEADER")

    captured = {}
    monkeypatch.setattr(ai_review, "Anthropic", lambda *a, **k: _fake_client(captured))
    monkeypatch.setattr(sys, "argv", ["ai_review.py", str(diff), str(thread)])
    ai_review.main()

    out = capsys.readouterr().out
    assert out.startswith("ROLE-HEADER")
    assert "LGTM" in out
    assert captured["model"] == "claude-sonnet-4-6"
    assert "PRIOR REVIEW THREAD" in captured["prompt"]
    assert "[Human] please fix the thing" in captured["prompt"]


def test_main_truncates_large_diff(tmp_path, monkeypatch, capsys):
    big = "--- a/x\n+++ b/x\n" + ("+line\n" * 5000)
    diff = tmp_path / "pr.diff"
    diff.write_text(big, encoding="utf-8")
    monkeypatch.setenv("AI_REVIEW_MAX_DIFF_CHARS", "500")

    captured = {}
    monkeypatch.setattr(ai_review, "Anthropic", lambda *a, **k: _fake_client(captured))
    monkeypatch.setattr(sys, "argv", ["ai_review.py", str(diff)])
    ai_review.main()

    out = capsys.readouterr().out
    assert "truncated to 500 chars" in out


def test_main_empty_diff(tmp_path, monkeypatch, capsys):
    diff = tmp_path / "pr.diff"
    diff.write_text("   \n", encoding="utf-8")
    monkeypatch.setattr(sys, "argv", ["ai_review.py", str(diff)])
    ai_review.main()
    assert "empty diff" in capsys.readouterr().out
