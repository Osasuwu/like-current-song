"""HTTP-level tests for GoogleSheetsStorage (#25).

`requests` is monkey-patched onto an in-memory simulator that mirrors
the real Sheets `values.get / values.update / values.append` semantics
just enough to drive the storage contract. The simulator is owned by
this module — the contract-level invariants live in
`tests/test_storage_contract.py`, which runs them against every shipped
`Storage` impl.
"""

from __future__ import annotations

import asyncio
import threading
from dataclasses import dataclass
from typing import Any

import pytest

from like_spotify.core.errors import TransientError
from like_spotify.core.types import CurrentTrack
from like_spotify.extensions.google_sheets_storage import GoogleSheetsStorage


@dataclass
class FakeResponse:
    status_code: int
    text: str = ""
    json_body: Any = None

    def json(self) -> Any:
        return self.json_body


class SheetsSim:
    """Minimal stand-in for Google Sheets' values endpoints."""

    def __init__(self, sheet: str = "Likes") -> None:
        # First row is the header; data starts at row index 2.
        self.rows: list[list] = [["user_id", "track_id", "count", "backfilled", "updated_at"]]
        self.sheet = sheet
        self.calls: list[tuple[str, str, dict]] = []

    def handle_get(self, url: str, **kw) -> FakeResponse:
        self.calls.append(("GET", url, kw))
        return FakeResponse(status_code=200, json_body={"values": list(self.rows)})

    def handle_post(self, url: str, **kw) -> FakeResponse:
        self.calls.append(("POST", url, kw))
        body = kw.get("json", {})
        values = body.get("values", [])
        if not values:
            return FakeResponse(status_code=400, text="no values")
        self.rows.extend(values)
        row_index = len(self.rows)  # 1-based; just appended row
        return FakeResponse(
            status_code=200,
            json_body={
                "updates": {
                    "updatedRange": f"{self.sheet}!A{row_index}:E{row_index}",
                }
            },
        )

    def handle_put(self, url: str, **kw) -> FakeResponse:
        self.calls.append(("PUT", url, kw))
        # Parse range from url tail: '.../values/Likes!C3:C3'
        tail = url.rsplit("/values/", 1)[-1]
        sheet, _, a1 = tail.partition("!")
        # Column letter + row number; only single-cell updates here.
        col_letter = a1.split(":")[0].rstrip("0123456789")
        row_digits = a1.split(":")[0][len(col_letter):]
        row = int(row_digits)
        col = ord(col_letter.upper()) - ord("A")
        new_value = kw["json"]["values"][0][0]
        while len(self.rows[row - 1]) <= col:
            self.rows[row - 1].append("")
        self.rows[row - 1][col] = new_value
        return FakeResponse(
            status_code=200,
            json_body={"updatedRange": f"{sheet}!{a1}", "updatedCells": 1},
        )


@pytest.fixture
def sim_and_storage(monkeypatch):
    sim = SheetsSim()
    monkeypatch.setattr(
        "like_spotify.extensions.google_sheets_storage.requests.get",
        sim.handle_get,
    )
    monkeypatch.setattr(
        "like_spotify.extensions.google_sheets_storage.requests.post",
        sim.handle_post,
    )
    monkeypatch.setattr(
        "like_spotify.extensions.google_sheets_storage.requests.put",
        sim.handle_put,
    )
    storage = GoogleSheetsStorage(
        spreadsheet_id="sheet-1",
        token_provider=lambda: "tok",
        sheet_name="Likes",
    )
    return sim, storage


def _track(track_id: str = "trk1") -> CurrentTrack:
    return CurrentTrack(
        provider="spotify", provider_track_id=track_id, title="t", artists=("a",)
    )


def test_constructor_rejects_missing_args() -> None:
    with pytest.raises(ValueError):
        GoogleSheetsStorage(spreadsheet_id="", token_provider=lambda: "t")
    with pytest.raises(ValueError):
        GoogleSheetsStorage(spreadsheet_id="s", token_provider=None)  # type: ignore[arg-type]


@pytest.mark.asyncio
async def test_first_encounter_appends_row(sim_and_storage) -> None:
    sim, storage = sim_and_storage

    count = await storage.increment("user-1", _track("trk-a"))

    assert count == 1
    methods = [c[0] for c in sim.calls]
    assert "GET" in methods  # one-time index load
    assert "POST" in methods  # append
    # Row landed: user_id, track_id, count, backfilled, updated_at
    last = sim.rows[-1]
    assert last[0] == "user-1"
    assert last[1] == "trk-a"
    assert last[2] == 1
    assert last[3] == "FALSE"


@pytest.mark.asyncio
async def test_first_encounter_was_already_liked_seeds_count_2(
    sim_and_storage,
) -> None:
    sim, storage = sim_and_storage

    count = await storage.increment(
        "user-1", _track("trk-a"), was_already_liked=True
    )

    assert count == 2
    last = sim.rows[-1]
    assert last[2] == 2
    assert last[3] == "TRUE"


@pytest.mark.asyncio
async def test_subsequent_increments_update_existing_row(sim_and_storage) -> None:
    sim, storage = sim_and_storage

    await storage.increment("user-1", _track("trk-a"))
    await storage.increment("user-1", _track("trk-a"))
    third = await storage.increment("user-1", _track("trk-a"))

    assert third == 3
    # Only ONE data row total — subsequent presses are UPDATEs, not APPENDs.
    data_rows = [r for r in sim.rows[1:] if r[0] == "user-1" and r[1] == "trk-a"]
    assert len(data_rows) == 1
    assert data_rows[0][2] == 3

    post_calls = [c for c in sim.calls if c[0] == "POST"]
    put_calls = [c for c in sim.calls if c[0] == "PUT"]
    assert len(post_calls) == 1  # only the first APPEND
    # Two PUTs per UPDATE press (count + updated_at), 2 presses past first → 4.
    assert len(put_calls) == 4


@pytest.mark.asyncio
async def test_backfill_flag_ignored_on_update(sim_and_storage) -> None:
    """The `was_already_liked` flag must only affect the INSERT row.
    Repeated True passes do not touch the `backfilled` column."""
    sim, storage = sim_and_storage

    await storage.increment("user-1", _track("trk-a"), was_already_liked=True)
    await storage.increment("user-1", _track("trk-a"), was_already_liked=True)
    final = await storage.increment("user-1", _track("trk-a"), was_already_liked=True)

    assert final == 4  # 2 (insert) + 1 + 1
    row = next(r for r in sim.rows[1:] if r[0] == "user-1" and r[1] == "trk-a")
    assert row[3] == "TRUE"


@pytest.mark.asyncio
async def test_get_count_returns_cached_value(sim_and_storage) -> None:
    sim, storage = sim_and_storage

    await storage.increment("user-1", _track("trk-a"))
    await storage.increment("user-1", _track("trk-a"))

    assert await storage.get_count("user-1", _track("trk-a")) == 2
    assert await storage.get_count("user-1", _track("missing")) == 0


@pytest.mark.asyncio
async def test_get_request_5xx_raises_transient(monkeypatch) -> None:
    monkeypatch.setattr(
        "like_spotify.extensions.google_sheets_storage.requests.get",
        lambda *a, **kw: FakeResponse(status_code=503, text="upstream"),
    )
    storage = GoogleSheetsStorage(
        spreadsheet_id="s", token_provider=lambda: "t"
    )
    with pytest.raises(TransientError):
        await storage.increment("u", _track())


@pytest.mark.asyncio
async def test_token_provider_invoked_per_call(sim_and_storage) -> None:
    sim, storage = sim_and_storage
    calls = []

    def provider() -> str:
        calls.append(1)
        return f"tok-{len(calls)}"

    storage._token = provider

    await storage.increment("user-1", _track())
    # GET (load) + POST (append) → 2 token calls minimum.
    assert len(calls) >= 2


# ── One pair, one row (#202) ─────────────────────────────────────────────


@pytest.mark.asyncio
async def test_warm_cache_miss_rereads_before_appending(sim_and_storage) -> None:
    """A row another device added after the cache loaded is UPDATEd.

    This is how the second row appeared: a tray host up for hours held a
    picture of the sheet from its first like and never looked again.
    """
    sim, storage = sim_and_storage

    # Load the cache with a like of a *different* track.
    await storage.increment("user-1", _track("other"))
    # Meanwhile, the phone appends a row for trk-a straight to the tab.
    sim.rows.append(["user-1", "trk-a", 4, "FALSE", "2026-01-01T00:00:00Z"])
    before = len(sim.calls)

    count = await storage.increment("user-1", _track("trk-a"))

    assert count == 5  # counted onto the row that was already there
    after = sim.calls[before:]
    assert [c[0] for c in after].count("GET") == 1  # the extra re-read
    assert not [c for c in after if c[0] == "POST"]  # and no second row
    rows = [r for r in sim.rows[1:] if r[1] == "trk-a"]
    assert len(rows) == 1
    assert rows[0][2] == 5


@pytest.mark.asyncio
async def test_cold_cache_does_not_read_twice(sim_and_storage) -> None:
    """The re-read is warm-cache only — a first like still costs one GET."""
    sim, storage = sim_and_storage

    await storage.increment("user-1", _track("trk-a"))

    methods = [c[0] for c in sim.calls]
    assert methods.count("GET") == 1
    assert methods.count("POST") == 1


@pytest.mark.asyncio
async def test_duplicate_rows_resolve_to_the_topmost(sim_and_storage) -> None:
    """`LikeCounter.findRow` (Kotlin) and `_ensureLoaded` (Dart) both take
    the first match; desktop has to take the same one or the counts drift."""
    sim, storage = sim_and_storage
    sim.rows.append(["user-1", "trk-a", 10, "FALSE", "2026-01-01T00:00:00Z"])  # row 2
    sim.rows.append(["user-1", "trk-a", 3, "FALSE", "2026-01-01T00:00:00Z"])  # row 3

    count = await storage.increment("user-1", _track("trk-a"))

    assert count == 11  # 10 + 1, i.e. the topmost row
    assert sim.rows[1][2] == 11
    assert sim.rows[2][2] == 3  # the spare is left exactly as it was


@pytest.mark.asyncio
async def test_duplicate_reported_once_and_nothing_deleted(sim_and_storage) -> None:
    sim, _unused = sim_and_storage
    notices: list[str] = []
    storage = GoogleSheetsStorage(
        spreadsheet_id="sheet-1",
        token_provider=lambda: "tok",
        sheet_name="Likes",
        notice=notices.append,
    )
    sim.rows.append(["user-1", "trk-a", 1, "FALSE", "2026-01-01T00:00:00Z"])
    sim.rows.append(["user-1", "trk-a", 1, "FALSE", "2026-01-01T00:00:00Z"])

    await storage.increment("user-1", _track("trk-a"))
    await storage.increment("user-1", _track("trk-a"))
    await storage.increment("user-1", _track("trk-a"))

    assert len(notices) == 1
    assert "rows 2 and 3" in notices[0]
    assert "trk-a" in notices[0]
    assert "add the counts up and delete the spare row" in notices[0]
    # No row is removed for the user — it is their spreadsheet.
    assert not [c for c in sim.calls if c[0] == "DELETE"]
    assert len(sim.rows) == 3


@pytest.mark.asyncio
async def test_duplicate_notice_defaults_to_the_logger(
    sim_and_storage, caplog
) -> None:
    sim, storage = sim_and_storage
    sim.rows.append(["user-1", "trk-a", 1, "FALSE", "2026-01-01T00:00:00Z"])
    sim.rows.append(["user-1", "trk-a", 1, "FALSE", "2026-01-01T00:00:00Z"])

    with caplog.at_level("WARNING"):
        await storage.increment("user-1", _track("trk-a"))

    assert any("more than one row" in r.getMessage() for r in caplog.records)


@pytest.mark.asyncio
async def test_two_racing_increments_make_one_row(sim_and_storage, monkeypatch) -> None:
    """Two likes of the same track, genuinely overlapping on two threads.

    `TrayHotkeyTrigger._on_hotkey` never waits on the future it schedules,
    so each press runs its own `run_once()`, and `increment` dispatches
    through `asyncio.to_thread` — two `_increment_sync` bodies on two OS
    threads. Here the first thread's GET is held until the second thread has
    genuinely entered `_increment_sync`, so the interleaving is forced
    rather than waited for: without the lock both bodies read "no row" and
    both append.
    """
    sim, storage = sim_and_storage

    both_entered = threading.Event()
    entered = 0
    entered_lock = threading.Lock()
    real_increment_sync = GoogleSheetsStorage._increment_sync

    def counting_increment_sync(self, *args):
        nonlocal entered
        with entered_lock:
            entered += 1
            if entered == 2:
                both_entered.set()
        return real_increment_sync(self, *args)

    monkeypatch.setattr(
        GoogleSheetsStorage, "_increment_sync", counting_increment_sync
    )

    def held_get(url: str, **kw):
        response = sim.handle_get(url, **kw)
        # Both presses are in flight by now, or the whole premise is wrong.
        assert both_entered.wait(timeout=10)
        return response

    monkeypatch.setattr(
        "like_spotify.extensions.google_sheets_storage.requests.get", held_get
    )

    results = await asyncio.gather(
        storage.increment("user-1", _track("trk-a")),
        storage.increment("user-1", _track("trk-a")),
    )

    data_rows = [r for r in sim.rows[1:] if r[1] == "trk-a"]
    assert len(data_rows) == 1  # not two
    assert data_rows[0][2] == 2
    assert sorted(results) == [1, 2]


@pytest.mark.asyncio
async def test_unparseable_append_range_is_not_cached_as_row_zero(
    sim_and_storage, monkeypatch
) -> None:
    """Row 0 would send the next like to `C0`; a re-read finds the real row."""
    sim, storage = sim_and_storage

    def post_without_range(url: str, **kw) -> FakeResponse:
        sim.handle_post(url, **kw)
        return FakeResponse(status_code=200, json_body={"updates": {}})

    monkeypatch.setattr(
        "like_spotify.extensions.google_sheets_storage.requests.post",
        post_without_range,
    )

    assert await storage.increment("user-1", _track("trk-a")) == 1
    assert ("user-1", "trk-a") not in (storage._row_index or {})

    # The next like re-reads, finds the row the append really made, and
    # updates it instead of writing to C0.
    assert await storage.increment("user-1", _track("trk-a")) == 2
    puts = [c for c in sim.calls if c[0] == "PUT"]
    assert puts and all("!C0" not in c[1] for c in puts)
    data_rows = [r for r in sim.rows[1:] if r[1] == "trk-a"]
    assert len(data_rows) == 1
    assert data_rows[0][2] == 2
