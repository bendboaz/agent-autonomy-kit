"""Unit tests for agent_token.mint / _env.

Locks down the token-request shape (endpoint, headers, JWT payload bounds) and
the error paths, without needing a real RSA key or network — jwt.encode and
requests.post are mocked. Run with: pytest (from infra/agent-ops/).
"""

from __future__ import annotations

from unittest import mock

import pytest

import agent_token

APP_ID = "4070567"
INSTALL_ID = "140736715"
FAKE_NOW = 1_000_000


@pytest.fixture
def env(monkeypatch):
    monkeypatch.setenv("GH_APP_ID", APP_ID)
    monkeypatch.setenv("GH_APP_INSTALLATION_ID", INSTALL_ID)
    monkeypatch.setenv("GH_APP_PRIVATE_KEY_PATH", "key.pem")
    monkeypatch.setattr(agent_token.time, "time", lambda: FAKE_NOW)


def _resp(status: int, body: dict | None = None):
    r = mock.Mock()
    r.status_code = status
    r.json.return_value = body or {}
    r.text = str(body)
    return r


def test_env_returns_value(monkeypatch):
    monkeypatch.setenv("FOO", "bar")
    assert agent_token._env("FOO") == "bar"


def test_env_missing_exits(monkeypatch):
    monkeypatch.delenv("FOO", raising=False)
    with pytest.raises(SystemExit):
        agent_token._env("FOO")


def test_mint_success_request_shape(env):
    with mock.patch("builtins.open", mock.mock_open(read_data=b"PEM")), mock.patch.object(
        agent_token.jwt, "encode", return_value="signed.jwt"
    ) as enc, mock.patch.object(
        agent_token.requests, "post", return_value=_resp(201, {"token": "ghs_abc"})
    ) as post:
        assert agent_token.mint() == "ghs_abc"

    # JWT payload: issuer is the app id; lifetime within GitHub's 10-min cap; iat backdated.
    payload = enc.call_args.args[0]
    assert payload["iss"] == APP_ID
    assert payload["iat"] == FAKE_NOW - 60
    assert 0 < (payload["exp"] - payload["iat"]) <= 600
    assert enc.call_args.kwargs["algorithm"] == "RS256"

    # Request targets the installation's access_tokens endpoint with the signed JWT + version header.
    url = post.call_args.args[0]
    headers = post.call_args.kwargs["headers"]
    assert url.endswith(f"/app/installations/{INSTALL_ID}/access_tokens")
    assert headers["Authorization"] == "Bearer signed.jwt"
    assert headers["X-GitHub-Api-Version"] == "2022-11-28"


def test_mint_http_error_exits(env):
    with mock.patch("builtins.open", mock.mock_open(read_data=b"PEM")), mock.patch.object(
        agent_token.jwt, "encode", return_value="signed.jwt"
    ), mock.patch.object(
        agent_token.requests, "post", return_value=_resp(403, {"message": "Forbidden"})
    ):
        with pytest.raises(SystemExit):
            agent_token.mint()
