"""HTTP-level tests for GoogleSheetsStorage (#25).

`requests` is monkey-patched onto an in-memory simulator that mirrors
the real Sheets `values.get / values.update / values.append` semantics
just enough to drive the storage contract. The simulator is owned by
this module — the contract-level invariants live in
`tests/test_storage_contract.py`, which runs them against every shipped
`Storage` impl.
"""

from __future__ import annotations

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
