"""Creating the counter spreadsheet, so nobody has to build one by hand.

One ``POST /v4/spreadsheets`` makes the file, both tabs and both header rows
in a single call. The scope it needs, ``spreadsheets``, is the one
``like_spotify/auth/google.py`` has always asked for, so an account that is
already authorised can do this without consenting to anything new.

Whether a spreadsheet is already configured is the caller's business: this
module makes one every time it is asked to.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

import requests

from like_spotify.core.errors import AuthError, TransientError

from .errors import sheets_api_disabled
from .schema import create_request_body

API_BASE = "https://sheets.googleapis.com/v4/spreadsheets"

#: Longer than a like's budget: the user asked for this and is watching.
DEFAULT_TIMEOUT = 15.0

TokenProvider = Callable[[], str]


@dataclass(frozen=True)
class CreatedSpreadsheet:
    """A spreadsheet just made in the user's Drive."""

    spreadsheet_id: str
    url: str | None = None


def create_counter_spreadsheet(
    token_provider: TokenProvider,
    *,
    session=None,
    timeout: float = DEFAULT_TIMEOUT,
) -> CreatedSpreadsheet:
    """Create the counter spreadsheet and answer its id.

    *session* is anything with a ``requests``-shaped ``post``; it defaults to
    :mod:`requests` itself and exists so this can be tested without network.

    Raises :class:`~.errors.SheetsApiDisabledError` when the refusal is a
    Cloud project without the Sheets API enabled, :class:`AuthError` when
    Google will not accept the token, :class:`TransientError` on a 5xx or a
    network blip, and :class:`RuntimeError` for anything else — including a
    2xx reply that carries no spreadsheet id.
    """
    if token_provider is None:
        raise ValueError("token_provider is required")
    http = session if session is not None else requests

    token = token_provider()
    if not token:
        raise AuthError("no Google access token for the counter")

    try:
        r = http.post(
            API_BASE,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            json=create_request_body(),
            timeout=timeout,
        )
    except requests.RequestException as exc:  # pragma: no cover - network only
        raise TransientError(f"sheets create failed: {exc}") from exc

    # Before the token is blamed: a 403 here is more often a project whose
    # Sheets API was never switched on than a bad token, and re-authorising
    # — what an AuthError asks a host to do — would not fix it (#165).
    disabled = sheets_api_disabled(r.status_code, r.text)
    if disabled is not None:
        raise disabled
    if r.status_code in (401, 403):
        raise AuthError(f"sheets create {r.status_code}: {r.text}")
    if r.status_code >= 500:
        raise TransientError(f"sheets create 5xx: {r.status_code}")
    if r.status_code >= 400:
        raise RuntimeError(f"sheets create {r.status_code}: {r.text}")

    body = r.json() or {}
    spreadsheet_id = body.get("spreadsheetId")
    if not spreadsheet_id:
        raise RuntimeError("sheets create: reply carried no spreadsheetId")
    return CreatedSpreadsheet(
        spreadsheet_id=spreadsheet_id,
        url=body.get("spreadsheetUrl") or None,
    )
