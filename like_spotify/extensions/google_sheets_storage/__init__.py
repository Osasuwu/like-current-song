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

One pair, one row (#202). The row *is* the counter, so a second row for a
`(user_id, track_id)` pair splits its count in two for good and the total
the user sees stays below the number of likes. Three rules keep that from
happening, and they are the same three the Android half runs (#193/#201):

* The `(user, track) -> row` cache may say a pair is *present*, but it is
  never trusted to say one is *absent*: a miss on a cache loaded earlier
  means re-read the tab, and only append if the pair is still missing.
  The phone and a second desktop instance append rows this process can
  never hear about. It costs one extra `values.get` on the append path —
  the first like of a track and nothing else.
* Read-then-write is serialized on `_lock`, so two likes in flight cannot
  both read "no row yet" and both append one.
* A tab that already holds two rows for one pair resolves to the
  **topmost** of them, and the spare is reported, never deleted.

Undo (#270) takes back the latest increment this instance made for a pair,
once. It re-reads the tab first, so a press the phone made in between is
kept: an update is undone by writing one less than the count the sheet holds
*now*, and an append by blanking the row it made — but only while that row
still holds the count it was seeded with. A row another device has added to
since is left alone, with an error. `updated_at` is not rolled back, and a
blanked row stays in the tab as an empty line, skipped by every reader.

The ArtistTracks tab gets the same once-only undo (#283). A record that
appended the triple blanks its row again, found by re-reading the tab, so
rows the phone or a second desktop appended since stay counted; a record
that found the triple already there wrote nothing and its undo writes
nothing. The tab is a set, not a counter, so any row of the triple will do;
the bottom-most is taken, as Android's `LikeCounter.artistTrackRow` does.
"""

from __future__ import annotations

import asyncio
import logging
import threading
import time
from collections.abc import Callable

import requests

from like_spotify.core.errors import TransientError
from like_spotify.core.storage import Storage
from like_spotify.core.types import CurrentTrack

from .create import CreatedSpreadsheet, create_counter_spreadsheet
from .errors import (
    SHEETS_API_LIBRARY_URL,
    SheetsApiDisabledError,
    sheets_api_disabled,
)
from .schema import (
    ARTIST_HEADER_ROW,
    COUNT_COLUMN,
    DEFAULT_ARTIST_SHEET,
    DEFAULT_SHEET,
    HEADER_ROW,
    SPREADSHEET_TITLE,
    UPDATED_AT_COLUMN,
    column_of,
    create_request_body,
)

DOMAIN = "google_sheets"

API_BASE = "https://sheets.googleapis.com/v4/spreadsheets"

logger = logging.getLogger(__name__)

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
    "SHEETS_API_LIBRARY_URL",
    "SheetsApiDisabledError",
    "SPREADSHEET_TITLE",
    "STORAGE",
    "UPDATED_AT_COLUMN",
    "create_counter_spreadsheet",
    "create_request_body",
    "sheets_api_disabled",
]


TokenProvider = Callable[[], str]
Notice = Callable[[str], None]


class GoogleSheetsStorage(Storage):
    def __init__(
        self,
        spreadsheet_id: str,
        token_provider: TokenProvider,
        sheet_name: str = DEFAULT_SHEET,
        artist_sheet_name: str = DEFAULT_ARTIST_SHEET,
        timeout: float = 5.0,
        notice: Notice | None = None,
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
        # Where a message about the *sheet* goes, as opposed to an error a
        # caller can act on. The default reaches the user through the
        # resident host's `startup.log` — the one log the tray can open.
        # A `notice` runs with `_lock` held, so it must not call back in.
        self._notice: Notice = notice if notice is not None else logger.warning
        # Filled on first access. Row index is 1-based and INCLUDES the
        # header row, so the first data row is index 2.
        self._row_index: dict[tuple[str, str], int] | None = None
        self._count_cache: dict[tuple[str, str], int] = {}
        # The lowest row holding any value, as of the last full read (#278).
        self._last_data_row = 1
        # #26 — distinct (user, artist, track) triples seen.
        self._artist_seen: set[tuple[str, str, str]] | None = None
        # Pairs already named as duplicated, so a sheet that carries one is
        # reported once and not on every press (#202).
        self._reported_duplicates: set[tuple[str, str]] = set()
        # #270 — what the latest increment of each pair did, so
        # `undo_increment` reverses exactly that once: `_UPDATED`, or the
        # count an append seeded. Popped by the undo, even one that fails.
        self._last_increment: dict[tuple[str, str], int] = {}
        # #283 — whether the latest record of each triple added it to the
        # ArtistTracks tab, so `undo_record_artist_track` takes back only a
        # track that record counted, once. Popped by the undo, even one that
        # fails.
        self._last_artist_record: dict[tuple[str, str, str], bool] = {}
        # The read-then-write round trip is serialized here, and the caches
        # above are only touched under it.
        #
        # Two increments really can overlap: `TrayHotkeyTrigger._on_hotkey`
        # fires on the `keyboard` library's worker thread and schedules the
        # emit with `asyncio.run_coroutine_threadsafe(...)` *without waiting
        # on the future*, so each press starts an independent
        # `pipeline.run_once()`; those coroutines interleave at every await,
        # and `increment` dispatches through `asyncio.to_thread`, which puts
        # two `_increment_sync` bodies on two OS threads at once. Both would
        # read "this pair has no row" and both would append one (#202).
        #
        # A plain `Lock` rather than an `RLock`: it is taken once, at the top
        # of each public `_sync` entry point, and every internal below
        # assumes it is already held. Nothing re-enters.
        self._lock = threading.Lock()

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

    async def undo_increment(self, user_id: str, track: CurrentTrack) -> int:
        return await asyncio.to_thread(
            self._undo_increment_sync, user_id, track.provider_track_id
        )

    async def record_artist_track(
        self, user_id: str, artist_id: str, track_id: str
    ) -> int:
        return await asyncio.to_thread(
            self._record_artist_track_sync, user_id, artist_id, track_id
        )

    async def undo_record_artist_track(
        self, user_id: str, artist_id: str, track_id: str
    ) -> int:
        return await asyncio.to_thread(
            self._undo_record_artist_track_sync, user_id, artist_id, track_id
        )

    # ── Internals ────────────────────────────────────────────────────────

    def _headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self._token()}",
            "Content-Type": "application/json",
        }

    def _invalidate(self) -> None:
        """Throw the row/count picture away so the next use re-reads the tab.

        Caller holds `_lock`.
        """
        self._row_index = None
        self._count_cache = {}

    def _ensure_loaded(self) -> None:
        """Load `(user, track) -> row` and the counts, once, until invalidated.

        The **topmost** row for a pair wins and the ones below it are left
        exactly where they are. That rule is shared by all three halves —
        `LikeCounter.findRow` (Kotlin) returns its first match and
        `_ensureLoaded` (Dart) keeps the first row it sees — so a sheet that
        already carries a duplicate has every half adding to the same row of
        it, instead of the counts drifting further apart with every like
        (#202). The spare rows are never deleted: it is the user's
        spreadsheet, and merging two counts is their call, not a counter's.
        They are reported once per pair instead, since nothing else would
        ever mention a split count.

        Caller holds `_lock`.
        """
        if self._row_index is not None:
            return
        r = requests.get(
            f"{API_BASE}/{self._sid}/values/{self._sheet}",
            headers=self._headers(),
            timeout=self._timeout,
        )
        if r.status_code >= 500:
            raise TransientError(f"sheets get 5xx: {r.status_code}")
        _raise_if_api_disabled(r)
        if r.status_code >= 400:
            raise RuntimeError(f"sheets get {r.status_code}: {r.text}")
        rows = r.json().get("values", []) or []
        index: dict[tuple[str, str], int] = {}
        counts: dict[tuple[str, str], int] = {}
        duplicates: dict[tuple[str, str], list[int]] = {}
        # Row 1 is the header; data starts at row 2.
        for offset, row in enumerate(rows[1:], start=2):
            if len(row) < 3:
                continue
            key = (row[0], row[1])
            if key in index:
                # Topmost already taken — this one is a spare. Remember it
                # so the user can be told, and never overwrite the index.
                duplicates.setdefault(key, []).append(offset)
                continue
            index[key] = offset
            try:
                counts[key] = int(row[2])
            except (TypeError, ValueError):
                counts[key] = 0
        self._row_index = index
        self._count_cache = counts
        self._last_data_row = max(
            (n for n, row in enumerate(rows, start=1) if any(c != "" for c in row)),
            default=1,
        )
        for key, spares in duplicates.items():
            self._report_duplicate(key, index[key], spares)

    def _report_duplicate(
        self, key: tuple[str, str], kept: int, spares: list[int]
    ) -> None:
        """Say, once per pair, that the sheet holds more than one row for it.

        A duplicate is permanent damage to a count that cannot be repaired
        from here without deleting a row off someone's spreadsheet, so it is
        named instead, with the rows to add up. Not an exception: the
        pipeline treats anything `increment` raises as "the counter failed"
        and drops the count to `None`, which would cost the user the number
        over a sheet that is merely untidy.

        Caller holds `_lock`.
        """
        if key in self._reported_duplicates:
            return
        self._reported_duplicates.add(key)
        spare_word = "row" if len(spares) == 1 else "rows"
        try:
            self._notice(
                f"The shared counter sheet has more than one row for track "
                f"{key[1]} (rows {_and_list([kept, *spares])}). Counting on "
                f"row {kept}; add the counts up and delete the spare "
                f"{spare_word} to see the real total."
            )
        except Exception:
            # A notice sink that throws must not cost the user their like.
            pass

    def _increment_sync(
        self, user_id: str, track_id: str, was_already_liked: bool
    ) -> int:
        with self._lock:
            return self._increment_locked(user_id, track_id, was_already_liked)

    def _increment_locked(
        self, user_id: str, track_id: str, was_already_liked: bool
    ) -> int:
        # A read this call made is as fresh as the sheet gets; a picture left
        # over from an earlier like is not. The cache may say a pair is on
        # the sheet, but it can never be trusted to say one is *absent*: the
        # phone and a second desktop instance append rows straight to the tab
        # and this process has no way to hear about them (#202). So a miss on
        # a warm cache means look again before appending — one extra read on
        # the first like of a track, against a second row that never merges
        # back. A cold cache is about to read anyway, so it pays nothing.
        was_cached = self._row_index is not None
        self._ensure_loaded()
        assert self._row_index is not None  # for type checker
        key = (user_id, track_id)

        if key not in self._row_index and was_cached:
            self._invalidate()
            self._ensure_loaded()
            assert self._row_index is not None

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
            self._last_increment[key] = _UPDATED
            return new_count

        # APPEND new row. Backfill flag honoured on this first encounter.
        new_count = 2 if was_already_liked else 1
        row = [user_id, track_id, new_count, "TRUE" if was_already_liked else "FALSE", now]
        appended_index = self._values_append(row)
        self._last_increment[key] = new_count
        # A range that could not be read is no row at all, so it is not
        # cached: row 0 would send the next like to `C0`. Leaving the pair
        # out means the next like re-reads the tab, finds the row this call
        # really did append, and adds to it (#202, as Dart does in #201).
        if appended_index > 0:
            self._row_index[key] = appended_index
            self._count_cache[key] = new_count
        return new_count

    def _undo_increment_sync(self, user_id: str, track_id: str) -> int:
        key = (user_id, track_id)
        with self._lock:
            seeded = self._last_increment.pop(key, None)
            if seeded is None:
                raise LookupError(f"no increment of {track_id} to undo")
            # The phone or a second desktop may have pressed since: read the
            # count the sheet holds now, not the one this instance last saw.
            self._invalidate()
            self._ensure_loaded()
            assert self._row_index is not None
            row_no = self._row_index.get(key)
            if row_no is None:
                raise RuntimeError(f"the counter row for {track_id} is gone")
            count = self._count_cache.get(key, 0)

            if seeded == _UPDATED:
                # The floor is 0, as on the phone: its undo (#272) leaves a
                # row it created at 0, and a like of that row here is 0 -> 1
                # (#278 S6).
                if count < 1:
                    raise RuntimeError(
                        f"the counter for {track_id} changed since the like "
                        f"(it reads {count}); left as it is"
                    )
                self._values_update(
                    f"{self._sheet}!{COUNT_COLUMN}{row_no}:{COUNT_COLUMN}{row_no}",
                    [[count - 1]],
                )
                self._count_cache[key] = count - 1
                return count - 1

            if count != seeded:
                raise RuntimeError(
                    f"the counter for {track_id} changed since the like "
                    f"(another device pressed?); left as it is"
                )
            if row_no != self._last_data_row:
                # A blank row inside the table can split it, so the next
                # `values.append` may insert above rows other devices have
                # cached by number (#278 S4). Only the last row is safe.
                raise RuntimeError(
                    f"another row was added below it since the like; the "
                    f"counter for {track_id} is left as it is"
                )
            self._values_clear(f"{self._sheet}!A{row_no}:{_LAST_COLUMN}{row_no}")
            del self._row_index[key]
            self._count_cache.pop(key, None)
            return 0

    def _get_count_sync(self, user_id: str, track_id: str) -> int:
        with self._lock:
            self._ensure_loaded()
            return self._count_cache.get((user_id, track_id), 0)

    def _ensure_artist_loaded(self) -> None:
        """Load the distinct `(user, artist, track)` triples, once.

        No warm-cache re-read here, unlike `_ensure_loaded`. This tab has no
        counter in it: it is a *set*, the per-artist number is recounted from
        the set in memory, and a reload collapses any repeated triple. A
        stale cache can therefore only cost a redundant row, never a split
        count — not worth a GET on the first like of every track (#202).

        Caller holds `_lock`.
        """
        if self._artist_seen is not None:
            return
        self._artist_seen = _triples(self._read_artist_rows())

    def _read_artist_rows(self) -> list[list]:
        """Read the ArtistTracks tab as it is now, header included.

        A tab that does not exist yet reads as empty: the append in
        `_record_artist_track_sync` will fail until the user creates it,
        consistent with first-run on the Likes sheet.

        Caller holds `_lock`.
        """
        r = requests.get(
            f"{API_BASE}/{self._sid}/values/{self._artist_sheet}",
            headers=self._headers(),
            timeout=self._timeout,
        )
        if r.status_code == 400:
            return []
        if r.status_code >= 500:
            raise TransientError(f"sheets get 5xx: {r.status_code}")
        _raise_if_api_disabled(r)
        if r.status_code >= 400:
            raise RuntimeError(f"sheets get {r.status_code}: {r.text}")
        return r.json().get("values", []) or []

    def _artist_count(self, user_id: str, artist_id: str) -> int:
        """Distinct tracks recorded for (user, artist). Caller holds `_lock`."""
        assert self._artist_seen is not None
        return sum(
            1
            for (u, a, _t) in self._artist_seen
            if u == user_id and a == artist_id
        )

    def _record_artist_track_sync(
        self, user_id: str, artist_id: str, track_id: str
    ) -> int:
        with self._lock:
            self._ensure_artist_loaded()
            assert self._artist_seen is not None
            triple = (user_id, artist_id, track_id)
            added = triple not in self._artist_seen
            if added:
                self._values_append_to(
                    self._artist_sheet,
                    [user_id, artist_id, track_id, _now_iso()],
                )
                self._artist_seen.add(triple)
            self._last_artist_record[triple] = added
            return self._artist_count(user_id, artist_id)

    def _undo_record_artist_track_sync(
        self, user_id: str, artist_id: str, track_id: str
    ) -> int:
        triple = (user_id, artist_id, track_id)
        with self._lock:
            added = self._last_artist_record.pop(triple, None)
            if added is None:
                raise LookupError(
                    f"no record of {track_id} for artist {artist_id} to undo"
                )
            if not added:
                # The track was on the record before this press counted it.
                self._ensure_artist_loaded()
                return self._artist_count(user_id, artist_id)
            # Read the tab as it is now: the phone or a second desktop may
            # have appended rows since, and those stay counted.
            rows = self._read_artist_rows()
            row_no = _bottom_row_of(rows, triple)
            if row_no is not None:
                # Blanking a row inside this tab is safe, unlike on Likes
                # (#278 S4): it is a set, and no half caches it by row
                # number. The phone's undo (#273) clears the same row.
                self._values_clear(
                    f"{self._artist_sheet}!A{row_no}:"
                    f"{_ARTIST_LAST_COLUMN}{row_no}"
                )
                rows = rows[: row_no - 1] + rows[row_no:]
            self._artist_seen = _triples(rows)
            return self._artist_count(user_id, artist_id)

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
        _raise_if_api_disabled(r)
        if r.status_code >= 400:
            raise RuntimeError(f"sheets update {r.status_code}: {r.text}")

    def _values_clear(self, range_a1: str) -> None:
        r = requests.post(
            f"{API_BASE}/{self._sid}/values/{range_a1}:clear",
            headers=self._headers(),
            json={},
            timeout=self._timeout,
        )
        if r.status_code >= 500:
            raise TransientError(f"sheets clear 5xx: {r.status_code}")
        _raise_if_api_disabled(r)
        if r.status_code >= 400:
            raise RuntimeError(f"sheets clear {r.status_code}: {r.text}")

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
        _raise_if_api_disabled(r)
        if r.status_code >= 400:
            raise RuntimeError(f"sheets append {r.status_code}: {r.text}")
        return r.json()


# ── Module-level helpers ─────────────────────────────────────────────────


# `_last_increment` value for an increment that updated an existing row; an
# append stores the count it seeded instead, which is always 1 or 2.
_UPDATED = 0
# The row an undone append blanks runs across the whole header.
_LAST_COLUMN = column_of(HEADER_ROW, HEADER_ROW[-1])
# The row an undone artist-track record blanks (#283).
_ARTIST_LAST_COLUMN = column_of(ARTIST_HEADER_ROW, ARTIST_HEADER_ROW[-1])


def _triples(rows: list[list]) -> set[tuple[str, str, str]]:
    """The distinct `(user, artist, track)` triples of an ArtistTracks read.

    Row 1 is the header; a row with fewer than three cells (a blanked one
    included) is skipped.
    """
    return {(row[0], row[1], row[2]) for row in rows[1:] if len(row) >= 3}


def _bottom_row_of(
    rows: list[list], triple: tuple[str, str, str]
) -> int | None:
    """1-based number of the lowest data row holding `triple`, or None.

    The lowest, as the Android half picks (`LikeCounter.artistTrackRow`).
    Which one does not change the count: the tab is a set, so with two
    rows for the triple, clearing either leaves the track counted.
    """
    for offset in range(len(rows), 1, -1):
        row = rows[offset - 1]
        if len(row) >= 3 and (row[0], row[1], row[2]) == triple:
            return offset
    return None


def _raise_if_api_disabled(r) -> None:
    """Say back what Google said, when the project has Sheets switched off.

    Creation is not the only way to meet that project: a counter configured
    by pasting an id never calls `create`, so the first thing it hits is a
    read here, which used to log `sheets get 403:` and a wall of JSON (#165).
    """
    disabled = sheets_api_disabled(r.status_code, getattr(r, "text", "") or "")
    if disabled is not None:
        raise disabled


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _and_list(numbers: list[int]) -> str:
    """'2', '2 and 5', '2, 5 and 9' — for a sentence the user reads."""
    if len(numbers) == 1:
        return str(numbers[0])
    head = ", ".join(str(n) for n in numbers[:-1])
    return f"{head} and {numbers[-1]}"


def _row_from_a1_range(a1: str) -> int:
    """Extract the row number from an A1 range like 'Likes!A7:E7' → 7.

    Returns 0 when there is no row number to read. Callers treat that as
    "no row", not as row 0 — see the append branch of `_increment_locked`.
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
