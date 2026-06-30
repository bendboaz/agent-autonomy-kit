r"""Mint a short-lived GitHub App *installation* access token.

The agent/dispatcher uses this token (as GH_TOKEN) so git/gh act AS the App
(non-admin identity), not as the human. The App private key is a secret: it is
read from a file path given by env, never hard-coded, never logged. Only the
short-lived installation token (ghs_...) is printed to stdout.

Env (or pass as needed):
  GH_APP_ID                e.g. 4070567
  GH_APP_INSTALLATION_ID   e.g. 140736715
  GH_APP_PRIVATE_KEY_PATH  path to the .pem (keep OUTSIDE the repo)

Usage (PowerShell):
  $env:GH_APP_ID="4070567"
  $env:GH_APP_INSTALLATION_ID="140736715"
  $env:GH_APP_PRIVATE_KEY_PATH="C:\Users\Boaz\.secrets\dnd-agent.pem"
  $env:GH_TOKEN = (python agent_token.py)      # now gh/git act as the App
  gh auth status   # or: git -c http.extraheader=... ; gh pr ...

Dependency:  pip install "pyjwt[crypto]" requests
"""

from __future__ import annotations

import os
import sys
import time

import jwt  # PyJWT
import requests

GITHUB_API = "https://api.github.com"


def _env(name: str) -> str:
    val = os.getenv(name)
    if not val:
        sys.exit(f"missing env var: {name}")
    return val


def mint() -> str:
    app_id = _env("GH_APP_ID")
    installation_id = _env("GH_APP_INSTALLATION_ID")
    key_path = _env("GH_APP_PRIVATE_KEY_PATH")

    with open(key_path, "rb") as f:
        private_key = f.read()

    now = int(time.time())
    # App JWT: 'iat' backdated 60s for clock skew, expires in <=10 min (GitHub cap).
    payload = {"iat": now - 60, "exp": now + 9 * 60, "iss": app_id}
    app_jwt = jwt.encode(payload, private_key, algorithm="RS256")

    resp = requests.post(
        f"{GITHUB_API}/app/installations/{installation_id}/access_tokens",
        headers={
            "Authorization": f"Bearer {app_jwt}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        timeout=15,
    )
    if resp.status_code >= 400:
        sys.exit(f"token request failed ({resp.status_code}): {resp.text[:300]}")
    return resp.json()["token"]


if __name__ == "__main__":
    print(mint())
