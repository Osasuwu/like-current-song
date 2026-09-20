"""Creating the counter spreadsheet (#152).

No network: the `requests`-shaped session is injected, and every test
asserts on the one request that leaves.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import pytest

from like_spotify.core.errors import AuthError, TransientError
from like_spotify.extensions.google_sheets_storage import schema
from like_spotify.extensions.google_sheets_storage.create import (
    API_BASE,
    create_counter_spreadsheet,
)

LIKES_HEADER = ["user_id", "track_id", "count", "backfilled", "updated_at"]
ARTIST_HEADER = ["user_id", "artist_id", "track_id", "created_at"]


@dataclass
class FakeResponse:
    status_code: int
    text: str = ""
    json_body: Any = None

    def json(self) -> Any:
        return self.json_body


@dataclass
class FakeSession:
    """Records the posts and answers a canned reply."""

    reply: FakeResponse
    posts: list[tuple[str, dict]] = field(default_factory=list)

    def post(self, url: str, **kw) -> FakeResponse:
        self.posts.append((url, kw))
        return self.reply


def ok(spreadsheet_id: str = "made-up-id", url: str | None = None) -> FakeResponse:
    body: dict[str, Any] = {"spreadsheetId": spreadsheet_id}
    if url:
        body["spreadsheetUrl"] = url
    return FakeResponse(status_code=200, json_body=body)


def header_of(tab: dict) -> list[str]:
    values = tab["data"][0]["rowData"][0]["values"]
    return [cell["userEnteredValue"]["stringValue"] for cell in values]


# ── The body ─────────────────────────────────────────────────────────────


def test_body_names_the_spreadsheet() -> None:
    assert schema.create_request_body()["properties"] == {
        "title": "Like Current Song counters"
    }


def test_body_creates_both_tabs_likes_first() -> None:
    tabs = schema.create_request_body()["sheets"]
    assert [tab["properties"]["title"] for tab in tabs] == ["Likes", "ArtistTracks"]


def test_body_types_both_header_rows_in_order_at_a1() -> None:
    tabs = schema.create_request_body()["sheets"]
    assert header_of(tabs[0]) == LIKES_HEADER
    assert header_of(tabs[1]) == ARTIST_HEADER
    for tab in tabs:
        assert len(tab["data"]) == 1
        assert tab["data"][0]["startRow"] == 0
        assert tab["data"][0]["startColumn"] == 0
        assert len(tab["data"][0]["rowData"]) == 1


# ── The call ─────────────────────────────────────────────────────────────


def test_one_post_carries_the_whole_spreadsheet() -> None:
    session = FakeSession(reply=ok(url="https://example.test/made-up-id"))

    created = create_counter_spreadsheet(lambda: "token", session=session)

    assert created.spreadsheet_id == "made-up-id"
    assert created.url == "https://example.test/made-up-id"
    assert len(session.posts) == 1
    url, kw = session.posts[0]
    assert url == API_BASE
    assert kw["headers"]["Authorization"] == "Bearer token"
    assert kw["json"] == schema.create_request_body()


def test_a_reply_without_a_url_still_gives_back_the_id() -> None:
    created = create_counter_spreadsheet(lambda: "token", session=FakeSession(ok()))
    assert created.spreadsheet_id == "made-up-id"
    assert created.url is None


def test_no_token_means_no_call() -> None:
    session = FakeSession(reply=ok())
    with pytest.raises(AuthError):
        create_counter_spreadsheet(lambda: "", session=session)
    assert session.posts == []


@pytest.mark.parametrize("status", [401, 403])
def test_a_refused_token_is_an_auth_error(status: int) -> None:
    session = FakeSession(reply=FakeResponse(status_code=status, text="nope"))
    with pytest.raises(AuthError):
        create_counter_spreadsheet(lambda: "token", session=session)


def test_a_5xx_is_transient() -> None:
    session = FakeSession(reply=FakeResponse(status_code=503, text="later"))
    with pytest.raises(TransientError):
        create_counter_spreadsheet(lambda: "token", session=session)


def test_another_refusal_is_reported_verbatim() -> None:
    session = FakeSession(reply=FakeResponse(status_code=400, text="bad request"))
    with pytest.raises(RuntimeError, match="bad request"):
        create_counter_spreadsheet(lambda: "token", session=session)


def test_a_2xx_with_no_id_is_a_failure() -> None:
    session = FakeSession(reply=FakeResponse(status_code=200, json_body={}))
    with pytest.raises(RuntimeError):
        create_counter_spreadsheet(lambda: "token", session=session)
