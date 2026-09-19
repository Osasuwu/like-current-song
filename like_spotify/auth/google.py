"""Google OAuth (installed-app) for the `google_sheets_storage` extension.

Mirrors the Spotify PKCE flow: open browser → loopback HTTP callback →
authorization-code exchange → persist tokens. Refresh is auto: callers
get a `token_provider` callable that returns a fresh access token.

Why a separate module: the Spotify extension owns its OAuth because
it's also the provider, but Google OAuth is reused only at host-wiring
time — `GoogleSheetsStorage` itself just takes a `() -> str` callable.
Putting the flow under `like_spotify/auth/` keeps it host-orthogonal
and reusable if another Google API is wrapped later.

Google requires a `client_secret` even for desktop apps (per the docs),
but the value is widely known to not be a real secret — it ships with
the binary in every desktop OAuth client. We persist it next to the
tokens for refresh; it never appears in logs.

Slice: #28 (folds in the deferred --setup wiring left over from #25).
"""

from __future__ import annotations

import base64
import hashlib
import http.server
import json
import secrets
import socketserver
import threading
import time
import urllib.parse
import webbrowser
from collections.abc import Callable
from pathlib import Path

import requests

from like_spotify.core.errors import AuthError, TransientError

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
SCOPE = "https://www.googleapis.com/auth/spreadsheets"

REDIRECT_PORT = 8794  # +1 vs the Spotify port so both can run in parallel.
REDIRECT_URI = f"http://127.0.0.1:{REDIRECT_PORT}/callback"


def authorize(
    client_id: str, client_secret: str, token_path: Path, scope: str = SCOPE
) -> dict:
    """Run the installed-app OAuth flow once. Persists + returns the
    token bundle (`access_token`, `refresh_token`, `expires_at`).

    `scope` defaults to Sheets; the YouTube Music provider passes its own
    and keeps its tokens in a separate file, so the two grants never mix.

    Raises `AuthError` if the user cancels / the callback times out.
    """
    if not client_id:
        raise ValueError("google client_id is required")
    if not client_secret:
        raise ValueError("google client_secret is required")

    verifier = secrets.token_urlsafe(64)[:96]
    challenge = (
        base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
        .rstrip(b"=")
        .decode()
    )
    state = secrets.token_hex(8)
    params = {
        "client_id": client_id,
        "response_type": "code",
        "redirect_uri": REDIRECT_URI,
        "scope": scope,
        "code_challenge_method": "S256",
        "code_challenge": challenge,
        "state": state,
        "access_type": "offline",
        "prompt": "consent",  # Force refresh_token issuance on re-auth.
    }
    url = f"{AUTH_URL}?{urllib.parse.urlencode(params)}"

    captured: dict[str, str | None] = {"code": None, "state": None, "error": None}
    event = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            captured["code"] = qs.get("code", [None])[0]
            captured["state"] = qs.get("state", [None])[0]
            captured["error"] = qs.get("error", [None])[0]
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            msg = (
                "Authorized! You can close this tab."
                if captured["code"]
                else f"Authorization failed: {captured['error'] or 'no code'}"
            )
            self.wfile.write(
                f"<h2 style='font-family:sans-serif;margin:40px'>{msg}</h2>".encode(
                    "utf-8"
                )
            )
            event.set()

        def log_message(self, *_args):
            pass

    # `allow_reuse_address` lets us re-bind a port that's still in
    # TIME_WAIT from a previous --setup run on the same shell. Without
    # it the second invocation crashed `--setup` with a bare OSError.
    class _ReusableServer(socketserver.TCPServer):
        allow_reuse_address = True

    try:
        server = _ReusableServer(("127.0.0.1", REDIRECT_PORT), Handler)
    except OSError as e:
        raise AuthError(
            f"could not bind 127.0.0.1:{REDIRECT_PORT} for the OAuth callback "
            f"({e}). Close anything using that port and re-run --setup."
        ) from e
    try:
        threading.Thread(target=server.handle_request, daemon=True).start()
        webbrowser.open(url)
        event.wait(timeout=180)
    finally:
        server.server_close()

    if captured["error"]:
        raise AuthError(f"google denied authorization: {captured['error']}")
    if not captured["code"]:
        raise AuthError("google authorization timed out (180s)")
    if captured["state"] != state:
        raise AuthError("state mismatch in google OAuth callback")

    r = requests.post(
        TOKEN_URL,
        data={
            "grant_type": "authorization_code",
            "code": captured["code"],
            "redirect_uri": REDIRECT_URI,
            "client_id": client_id,
            "client_secret": client_secret,
            "code_verifier": verifier,
        },
        timeout=10,
    )
    if r.status_code >= 400:
        raise AuthError(f"google token exchange failed ({r.status_code}): {r.text}")
    tokens = _augment(r.json())
    # We persist the (clientid, secret) next to the tokens so a later
    # refresh from a long-lived host doesn't need them re-prompted.
    tokens["client_id"] = client_id
    tokens["client_secret"] = client_secret
    save_tokens(token_path, tokens)
    return tokens


def load_tokens(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def save_tokens(path: Path, tokens: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(tokens, indent=2), encoding="utf-8")


def make_token_provider(token_path: Path) -> Callable[[], str]:
    """Return a callable that yields a fresh access token, refreshing as
    needed. Suitable for `GoogleSheetsStorage(token_provider=...)`.

    Thread-safe via a local lock; the storage extension can call this
    from any of its `asyncio.to_thread` workers without coordination.
    """
    lock = threading.Lock()
    state: dict = load_tokens(token_path)

    def provider() -> str:
        with lock:
            if not state.get("refresh_token"):
                raise AuthError(
                    "google not authenticated; run `like-spotify --setup` first"
                )
            if time.time() > state.get("expires_at", 0) - 60:
                _refresh(state, token_path)
            return state["access_token"]

    return provider


# ── Internals ──────────────────────────────────────────────────────────


def _augment(payload: dict) -> dict:
    tokens = dict(payload)
    tokens["expires_at"] = time.time() + tokens.get("expires_in", 3600)
    return tokens


def _refresh(state: dict, token_path: Path) -> None:
    client_id = state.get("client_id")
    client_secret = state.get("client_secret")
    if not client_id or not client_secret:
        raise AuthError(
            "google client_id/secret missing from token store; "
            "re-run `like-spotify --setup --reauth`"
        )
    r = requests.post(
        TOKEN_URL,
        data={
            "grant_type": "refresh_token",
            "refresh_token": state["refresh_token"],
            "client_id": client_id,
            "client_secret": client_secret,
        },
        timeout=10,
    )
    if r.status_code in (400, 401):
        raise AuthError(f"google refresh rejected ({r.status_code}): {r.text}")
    if r.status_code >= 500:
        raise TransientError(f"google token endpoint 5xx: {r.status_code}")
    if r.status_code >= 400:
        raise AuthError(f"google token refresh failed: {r.status_code} {r.text}")
    fresh = r.json()
    state["access_token"] = fresh["access_token"]
    state["expires_at"] = time.time() + fresh["expires_in"]
    if "refresh_token" in fresh:
        state["refresh_token"] = fresh["refresh_token"]
    save_tokens(token_path, state)
