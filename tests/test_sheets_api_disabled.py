"""Reading Google's "the Sheets API is off" refusal (#165).

The bodies below are the shapes Google actually sends, typed out here
rather than built by the code under test: a test that asked the parser
what a refusal looks like would agree with any change to it.

Every test is offline — the `requests`-shaped session is injected, or
`requests` itself is monkeypatched onto an in-memory stand-in.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

import pytest

from like_spotify.core.errors import AuthError, UserActionRequired
from like_spotify.core.types import CurrentTrack
from like_spotify.extensions.google_sheets_storage import GoogleSheetsStorage
from like_spotify.extensions.google_sheets_storage.create import (
    create_counter_spreadsheet,
)
from like_spotify.extensions.google_sheets_storage.errors import (
    SHEETS_API_LIBRARY_URL,
    SheetsApiDisabledError,
    sheets_api_disabled,
)

ACTIVATION_URL = (
    "https://console.developers.google.com/apis/api/sheets.googleapis.com/"
    "overview?project=123456789"
)

PROSE = (
    "Google Sheets API has not been used in project 123456789 before or it "
    f"is disabled. Enable it by visiting {ACTIVATION_URL} then retry. If you "
    "enabled this API recently, wait a few minutes."
)

#: What the API sends today: a `google.rpc.ErrorInfo` among `error.details`.
CURRENT_SHAPE = json.dumps(
    {
        "error": {
            "code": 403,
            "message": PROSE,
            "status": "PERMISSION_DENIED",
            "details": [
                {
                    "@type": "type.googleapis.com/google.rpc.ErrorInfo",
                    "reason": "SERVICE_DISABLED",
                    "domain": "googleapis.com",
                    "metadata": {
                        "consumer": "projects/123456789",
                        "service": "sheets.googleapis.com",
                        "activationUrl": ACTIVATION_URL,
                    },
                },
                {
                    "@type": "type.googleapis.com/google.rpc.LocalizedMessage",
                    "locale": "en-US",
                    "message": PROSE,
                },
            ],
        }
    }
)

#: The older spelling, which carries the reason and nothing else — whatever
#: it can tell us about the project and the URL is in the prose.
OLD_SHAPE = json.dumps(
    {
        "error": {
            "code": 403,
            "message": f"Access Not Configured. {PROSE}",
            "errors": [
                {
                    "domain": "usageLimits",
                    "reason": "accessNotConfigured",
                    "message": f"Access Not Configured. {PROSE}",
                }
            ],
        }
    }
)


# ── The parser ───────────────────────────────────────────────────────────


def test_the_current_shape_names_the_page_that_fixes_it() -> None:
    error = sheets_api_disabled(403, CURRENT_SHAPE)

    assert error is not None
    assert error.activation_url == ACTIVATION_URL
    assert error.project == "123456789"
    assert "Google Sheets API is not enabled" in str(error)
    # The status code was never the point; the URL and the project are.
    assert ACTIVATION_URL in str(error)
    assert "123456789" in str(error)


def test_the_old_shape_is_read_too() -> None:
    error = sheets_api_disabled(403, OLD_SHAPE)

    assert error is not None
    # Nothing in this shape holds the URL as a field, so it comes out of
    # the prose.
    assert error.activation_url == ACTIVATION_URL
    assert error.project == "123456789"


def test_a_url_that_ends_the_sentence_keeps_no_full_stop() -> None:
    # A link with a stray "." on the end is a 404 for whoever taps it.
    body = json.dumps(
        {
            "error": {
                "message": f"Enable it by visiting {ACTIVATION_URL}.",
                "errors": [{"reason": "accessNotConfigured"}],
            }
        }
    )

    error = sheets_api_disabled(403, body)

    assert error is not None
    assert error.activation_url == ACTIVATION_URL


def test_a_disabled_reason_without_a_url_falls_back_to_the_library() -> None:
    body = json.dumps(
        {"error": {"message": "nope", "details": [{"reason": "SERVICE_DISABLED"}]}}
    )

    error = sheets_api_disabled(403, body)

    assert error is not None
    assert error.activation_url == SHEETS_API_LIBRARY_URL
    assert error.project is None
    # Still a complete instruction, even with Google saying almost nothing.
    assert "Google Sheets API is not enabled" in str(error)


@pytest.mark.parametrize(
    "body",
    [
        "",
        "   ",
        "<html>403 Forbidden</html>",
        "{",
        "[]",
        json.dumps({"error": "forbidden"}),
        json.dumps({"error": {"message": "Request had insufficient scopes."}}),
        json.dumps(
            {
                "error": {
                    "message": "revoked",
                    "details": [{"reason": "ACCESS_TOKEN_EXPIRED"}],
                }
            }
        ),
    ],
    ids=[
        "empty",
        "blank",
        "html",
        "truncated",
        "not-an-object",
        "error-is-a-string",
        "some-other-403",
        "a-reason-we-do-not-claim",
    ],
)
def test_anything_else_is_left_alone(body: str) -> None:
    # Guessing "your API is off" at someone whose API is on would be worse
    # than the status code they used to get.
    assert sheets_api_disabled(403, body) is None


def test_only_a_403_is_read_this_way() -> None:
    # A 404 or a 500 that happens to quote the same reason is a different
    # failure, and the caller's own branches already say so.
    assert sheets_api_disabled(404, CURRENT_SHAPE) is None
    assert sheets_api_disabled(500, CURRENT_SHAPE) is None


def test_it_is_not_an_auth_error() -> None:
    # Re-authorising fixes nothing here, so no host should be told to send
    # the user back through a sign-in they just finished.
    error = sheets_api_disabled(403, CURRENT_SHAPE)
    assert isinstance(error, RuntimeError)
    assert not isinstance(error, AuthError)


# ── Creating a spreadsheet ───────────────────────────────────────────────


@dataclass
class FakeResponse:
    status_code: int
    text: str = ""
    json_body: Any = None

    def json(self) -> Any:
        return self.json_body


@dataclass
class FakeSession:
    reply: FakeResponse
    posts: list[tuple[str, dict]] = field(default_factory=list)

    def post(self, url: str, **kw) -> FakeResponse:
        self.posts.append((url, kw))
        return self.reply


def test_create_reports_the_disabled_api_rather_than_the_token() -> None:
    session = FakeSession(reply=FakeResponse(status_code=403, text=CURRENT_SHAPE))

    with pytest.raises(SheetsApiDisabledError) as caught:
        create_counter_spreadsheet(lambda: "token", session=session)

    assert caught.value.activation_url == ACTIVATION_URL
    assert "Google Sheets API is not enabled" in str(caught.value)


def test_create_still_calls_a_plain_403_an_auth_error() -> None:
    # The body has to say so; a 403 for a revoked token is still a token
    # problem and must keep the branch that asks for a new one.
    session = FakeSession(reply=FakeResponse(status_code=403, text="nope"))

    with pytest.raises(AuthError):
        create_counter_spreadsheet(lambda: "token", session=session)


# ── Counting into a sheet ────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_a_paste_configured_counter_says_it_too(monkeypatch) -> None:
    """Creation is not the only way to meet a project with Sheets off.

    A counter set up by pasting an id never calls `create`, so the read
    below is the first thing that ever touches the API — and it used to
    log a status code and a wall of JSON.
    """
    monkeypatch.setattr(
        "like_spotify.extensions.google_sheets_storage.requests.get",
        lambda *_a, **_kw: FakeResponse(status_code=403, text=CURRENT_SHAPE),
    )
    storage = GoogleSheetsStorage(
        spreadsheet_id="sheet-1", token_provider=lambda: "tok"
    )

    with pytest.raises(SheetsApiDisabledError, match="not enabled"):
        await storage.get_count("user-1", _track())


def test_the_disabled_api_is_a_failure_only_the_user_can_clear() -> None:
    """What makes the like path show it instead of only logging it (#168)."""
    error = SheetsApiDisabledError("off", activation_url=SHEETS_API_LIBRARY_URL)

    assert isinstance(error, UserActionRequired)
    # Still a RuntimeError, so nothing that caught it before stops doing so.
    assert isinstance(error, RuntimeError)
    assert not isinstance(error, AuthError)


def _track() -> CurrentTrack:
    return CurrentTrack(
        provider="spotify", provider_track_id="trk-a", title="t", artists=("a",)
    )
