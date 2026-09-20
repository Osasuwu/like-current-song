"""GoogleSheetsStorage — second Storage impl.

Ships as the second reference impl that validates the `Storage`
abstraction with a backend that's not a SQL-style RPC. Forces the
interface to honour append + lookup-by-key semantics without leaking
PostgREST shape.

Sheet schema (per #25) lives in `schema.py`, shared with the two other
halves that write the same spreadsheet and with the code that creates it
(`create.py`): a single header row, then the data. The first action reads the sheet
once to build an in-memory `(user_id, track_id) -> row_index` map;
subsequent likes do a targeted `values.update` or, on miss, a single
`values.append`. The backfill flag from #24 is honoured: on the very
first insert with `was_already_liked=True`, count is seeded at 2 and
`backfilled` is set to `TRUE`; on every subsequent press, the row is
updated to `count + 1` and `backfilled` stays as it was.

OAuth is owner-managed: the constructor takes a `token_provider`
callable that returns a fresh access token at call time. The host
wires that to whatever refresh strategy it likes (the `--setup`
integration lands separately in #28).
"""

from __future__ import annotations

import asyncio
import time
from collections.abc import Callable

import requests

from like_spotify.core.errors import TransientError
from like_spotify.core.storage import Storage
from like_spotify.core.types import CurrentTrack

from .create import CreatedSpreadsheet, create_counter_spreadsheet
from .schema import (
    ARTIST_HEADER_ROW,
    COUNT_COLUMN,
    DEFAULT_ARTIST_SHEET,
    DEFAULT_SHEET,
    HEADER_ROW,
    SPREADSHEET_TITLE,
    UPDATED_AT_COLUMN,
    create_request_body,
)

DOMAIN = "google_sheets"

API_BASE = "https://sheets.googleapis.com/v4/spreadsheets"

__all__ = [
    "ARTIST_HEADER_ROW",
    "API_BASE",
    "COUNT_COLUMN",
    "CreatedSpreadsheet",
    "DEFAULT_ARTIST_SHEET",
    "DEFAULT_SHEET",
    "DOMAIN",
    "GoogleSheetsStorage",
    "HEADER_ROW",
    "SPREADSHEET_TITLE",
    "STORAGE",
    "UPDATED_AT_COLUMN",
    "create_counter_spreadsheet",
    "create_request_body",
]


TokenProvider = Callable[[], str]


class GoogleSheetsStorage(Storage):
    def __init__(
        self,
        spreadsheet_id: str,
        token_provider: TokenProvider,
        sheet_name: str = DEFAULT_SHEET,
        artist_sheet_name: str = DEFAULT_ARTIST_SHEET,
        timeout: float = 5.0,
    ) -> None:
        if not spreadsheet_id:
            raise ValueError("spreadsheet_id is required")
        if token_provider is None:
            raise ValueError("token_provider is required")
        self._sid = spreadsheet_id
        self._token = token_provider
        self._sheet = sheet_name
        self._artist_sheet = artist_sheet_name
        self._timeout = timeout
        # Filled on first access. Row index is 1-based and INCLUDES the
        # header row, so the first data row is index 2.
        self._row_index: dict[tuple[str, str], int] | None = None
        self._count_cache: dict[tuple[str, str], int] = {}
        # #26 — distinct (user, artist, track) triples seen.
        self._artist_seen: set[tuple[str, str, str]] | None = None

    async def increment(
        self,
        user_id: str,
        track: CurrentTrack,
        was_already_liked: bool = False,
    ) -> int:
        return await asyncio.to_thread(
            self._increment_sync, user_id, track.provider_track_id, was_already_liked
        )

    async def get_count(self, user_id: str, track: CurrentTrack) -> int:
        return await asyncio.to_thread(
            self._get_count_sync, user_id, track.provider_track_id
        )

    async def record_artist_track(
        self, user_id: str, artist_id: str, track_id: str
    ) -> int:
        return await asyncio.to_thread(
            self._record_artist_track_sync, user_id, artist_id, track_id
        )

    # ── Internals ────────────────────────────────────────────────────────

    def _headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self._token()}",
            "Content-Type": "application/json",
        }

    def _ensure_loaded(self) -> None:
        if self._row_index is not None:
            return
        r = requests.get(
            f"{API_BASE}/{self._sid}/values/{self._sheet}",
            headers=self._headers(),
            timeout=self._timeout,
        )
        if r.status_code >= 500:
            raise TransientError(f"sheets get 5xx: {r.status_code}")
        if r.status_code >= 400:
            raise RuntimeError(f"sheets get {r.status_code}: {r.text}")
        rows = r.json().get("values", []) or []
        index: dict[tuple[str, str], int] = {}
        counts: dict[tuple[str, str], int] = {}
        # Row 1 is the header; data starts at row 2.
        for offset, row in enumerate(rows[1:], start=2):
            if len(row) < 3:
                continue
            key = (row[0], row[1])
            index[key] = offset
            try:
                counts[key] = int(row[2])
            except (TypeError, ValueError):
                counts[key] = 0
        self._row_index = index
        self._count_cache = counts

    def _increment_sync(
        self, user_id: str, track_id: str, was_already_liked: bool
    ) -> int:
        self._ensure_loaded()
        assert self._row_index is not None  # for type checker
        key = (user_id, track_id)
        now = _now_iso()

        if key in self._row_index:
            new_count = self._count_cache.get(key, 0) + 1
            # Targeted UPDATE; leave the backfilled column alone, rewrite
            # count and updated_at. The letters come from the shared header.
            row_no = self._row_index[key]
            self._values_update(
                f"{self._sheet}!{COUNT_COLUMN}{row_no}:{COUNT_COLUMN}{row_no}",
                [[new_count]],
            )
            self._values_update(
                f"{self._sheet}!{UPDATED_AT_COLUMN}{row_no}:{UPDATED_AT_COLUMN}{row_no}",
                [[now]],
            )
            self._count_cache[key] = new_count
            return new_count

        # APPEND new row. Backfill flag honoured on this first encounter.
        new_count = 2 if was_already_liked else 1
        row = [user_id, track_id, new_count, "TRUE" if was_already_liked else "FALSE", now]
        appended_index = self._values_append(row)
        self._row_index[key] = appended_index
        self._count_cache[key] = new_count
        return new_count

    def _get_count_sync(self, user_id: str, track_id: str) -> int:
        self._ensure_loaded()
        return self._count_cache.get((user_id, track_id), 0)

    def _ensure_artist_loaded(self) -> None:
        if self._artist_seen is not None:
            return
        r = requests.get(
            f"{API_BASE}/{self._sid}/values/{self._artist_sheet}",
            headers=self._headers(),
            timeout=self._timeout,
        )
        if r.status_code == 400:
            # Sheet tab doesn't exist yet — start empty; the append below
            # will fail until the user creates the tab. Keep behaviour
            # consistent with first-run on the Likes sheet.
            self._artist_seen = set()
            return
        if r.status_code >= 500:
            raise TransientError(f"sheets get 5xx: {r.status_code}")
        if r.status_code >= 400:
            raise RuntimeError(f"sheets get {r.status_code}: {r.text}")
        rows = r.json().get("values", []) or []
        seen: set[tuple[str, str, str]] = set()
        for row in rows[1:]:
            if len(row) >= 3:
                seen.add((row[0], row[1], row[2]))
        self._artist_seen = seen

    def _record_artist_track_sync(
        self, user_id: str, artist_id: str, track_id: str
    ) -> int:
        self._ensure_artist_loaded()
        assert self._artist_seen is not None
        triple = (user_id, artist_id, track_id)
        if triple not in self._artist_seen:
            self._values_append_to(
                self._artist_sheet,
                [user_id, artist_id, track_id, _now_iso()],
            )
            self._artist_seen.add(triple)
        # Count distinct tracks for this (user, artist).
        return sum(
            1 for (u, a, _t) in self._artist_seen if u == user_id and a == artist_id
        )

    def _values_update(self, range_a1: str, values: list[list]) -> None:
        r = requests.put(
            f"{API_BASE}/{self._sid}/values/{range_a1}",
            headers=self._headers(),
            params={"valueInputOption": "RAW"},
            json={"values": values},
            timeout=self._timeout,
        )
        if r.status_code >= 500:
            raise TransientError(f"sheets update 5xx: {r.status_code}")
        if r.status_code >= 400:
            raise RuntimeError(f"sheets update {r.status_code}: {r.text}")

    def _values_append(self, row: list) -> int:
        """Append one row to the primary Likes sheet; return the 1-based
        row index it landed on."""
        body = self._values_append_to(self._sheet, row)
        updated_range = (body.get("updates") or {}).get("updatedRange", "")
        return _row_from_a1_range(updated_range)

    def _values_append_to(self, sheet: str, row: list) -> dict:
        r = requests.post(
            f"{API_BASE}/{self._sid}/values/{sheet}:append",
            headers=self._headers(),
            params={
                "valueInputOption": "RAW",
                "insertDataOption": "INSERT_ROWS",
            },
            json={"values": [row]},
            timeout=self._timeout,
        )
        if r.status_code >= 500:
            raise TransientError(f"sheets append 5xx: {r.status_code}")
        if r.status_code >= 400:
            raise RuntimeError(f"sheets append {r.status_code}: {r.text}")
        return r.json()


# ── Module-level helpers ─────────────────────────────────────────────────


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _row_from_a1_range(a1: str) -> int:
    """Extract the row number from an A1 range like 'Likes!A7:E7' → 7.

    Falls back to a large number on parse failure so the index stays
    consistent enough for in-memory use (a refresh re-syncs anyway).
    """
    # Find the last numeric run in the string.
    digits = ""
    for ch in reversed(a1):
        if ch.isdigit():
            digits = ch + digits
        elif digits:
            break
    try:
        return int(digits)
    except ValueError:
        return 0


def STORAGE(
    spreadsheet_id: str,
    token_provider: TokenProvider,
    sheet_name: str = DEFAULT_SHEET,
) -> GoogleSheetsStorage:
    """Factory called by the host. Signature widens in #28 (manifest deps)."""
    return GoogleSheetsStorage(
        spreadsheet_id=spreadsheet_id,
        token_provider=token_provider,
        sheet_name=sheet_name,
    )
