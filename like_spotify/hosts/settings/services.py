"""Settings window — side effects that aren't `config.json`.

Account connection (the same OAuth entry points `--setup` calls: the
provider's own `authorize` for Spotify / YouTube Music, and
`auth.google.authorize` for the Sheets counter) and the Windows autostart
toggle. Toolkit-free, so the window stays a thin view and these stay
reachable from tests.

Everything goes through `_common.<name>` at call time, the same as
`_setup.py`, so tests that redirect token paths or monkeypatch the
provider factories affect the window too.

The `connect_*` functions block until the browser round-trip finishes (or
times out inside the auth helper), so the window runs them on a worker
thread.
"""

from __future__ import annotations

import sys

from like_spotify.auth import google as google_auth
from like_spotify.extensions.google_sheets_storage.create import (
    CreatedSpreadsheet,
    create_counter_spreadsheet,
)
from like_spotify.extensions.google_sheets_storage.errors import (
    SHEETS_API_LIBRARY_URL,
    SheetsApiDisabledError,
)

from .. import _common

YTMUSIC_SETUP_URL = (
    "https://github.com/Osasuwu/like-current-song/blob/main/"
    "like_spotify/extensions/ytmusic/README.md"
)
SPOTIFY_DASHBOARD_URL = "https://developer.spotify.com/dashboard"
SPOTIFY_REDIRECT_URI = "http://127.0.0.1:8793/callback"
GOOGLE_CREDENTIALS_URL = "https://console.cloud.google.com/apis/credentials"
#: Creating the client and enabling the API are two different pages, and the
#: credentials one above cannot do the second — hence its own link (#165).
GOOGLE_SHEETS_API_URL = SHEETS_API_LIBRARY_URL


# ── Account status ─────────────────────────────────────────────────────


def spotify_connected(client_id: str) -> bool:
    if not client_id.strip():
        return False
    try:
        return bool(_common.make_provider(client_id.strip()).has_tokens)
    except Exception:
        return False


def ytmusic_connected() -> bool:
    try:
        return bool(_common.make_ytmusic().has_tokens)
    except Exception:
        return False


def sheets_connected() -> bool:
    return bool(google_auth.load_tokens(_common.GOOGLE_TOKEN_FILE).get("refresh_token"))


def saved_google_client(which: str) -> tuple[str, str]:
    """(client_id, client_secret) saved next to the YouTube or Sheets tokens.

    `--setup` persists them with the tokens so a re-login doesn't re-ask;
    the window pre-fills its fields from the same place.
    """
    path = _common.YOUTUBE_TOKEN_FILE if which == "ytmusic" else _common.GOOGLE_TOKEN_FILE
    tokens = google_auth.load_tokens(path)
    return tokens.get("client_id", "") or "", tokens.get("client_secret", "") or ""


# ── Connect (blocking: browser OAuth round-trip) ───────────────────────


def connect_spotify(client_id: str) -> None:
    client_id = client_id.strip()
    if not client_id:
        raise ValueError("enter the Spotify Client ID first")
    _common.make_provider(client_id).authorize()


def connect_ytmusic(client_id: str, client_secret: str) -> None:
    client_id, client_secret = client_id.strip(), client_secret.strip()
    if not client_id or not client_secret:
        raise ValueError("enter the Google OAuth Client ID and Client Secret first")
    _common.make_ytmusic().authorize(client_id=client_id, client_secret=client_secret)


def connect_sheets(client_id: str, client_secret: str) -> None:
    client_id, client_secret = client_id.strip(), client_secret.strip()
    if not client_id or not client_secret:
        raise ValueError("enter the Google OAuth Client ID and Client Secret first")
    google_auth.authorize(
        client_id=client_id,
        client_secret=client_secret,
        token_path=_common.GOOGLE_TOKEN_FILE,
    )


def create_counter_sheet() -> CreatedSpreadsheet:
    """Make the counter spreadsheet in the signed-in account's Drive.

    Blocking like the `connect_*` functions above, for the same reason: one
    HTTP round-trip the window runs on a worker thread. Whether one is
    already configured is the caller's call — the window refuses that, so
    nobody makes a second sheet the counts then split across.
    """
    if not sheets_connected():
        raise ValueError("connect Google first — creating a sheet needs the tokens")
    return create_counter_spreadsheet(
        google_auth.make_token_provider(_common.GOOGLE_TOKEN_FILE)
    )


def describe_create_failure(error: Exception) -> str:
    """The status line for a failed *Create spreadsheet*.

    Lives here rather than in the window so it can be read by a test that
    does not need a toolkit. A project with the Sheets API switched off
    already says exactly what to do, so it is shown on its own; anything
    else keeps the prefix that says which button failed (#165).
    """
    if isinstance(error, SheetsApiDisabledError):
        return str(error)
    return f"Could not create the spreadsheet: {error}"


# ── Autostart (Windows only) ───────────────────────────────────────────


def autostart_supported() -> bool:
    return sys.platform == "win32"


def autostart_enabled() -> bool | None:
    """Current state, or None when unsupported / unreadable."""
    if not autostart_supported():
        return None
    try:
        from like_spotify.hosts.windows import autostart

        return autostart._autostart_enabled()
    except Exception:
        return None


def set_autostart(enabled: bool) -> None:
    from like_spotify.hosts.windows import autostart

    autostart._autostart_set(enabled)
