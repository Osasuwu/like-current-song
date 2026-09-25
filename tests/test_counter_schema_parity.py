"""The three halves must describe the counter spreadsheet identically.

The Dart repository, the native Kotlin counter and this package all write the
same Google Sheet. While a human typed the header row, a drift between them
showed up as a puzzling bug report. Now the app creates the spreadsheet and
types the header itself, so a drift means one half appends rows another half
will never find — silently, since every call still returns 2xx.

Reading the other halves' source is deliberate: a shared fixture file would
be one more thing to keep in step. These are literal declarations, so a plain
parse is enough, and a rename that outruns this test fails loudly here rather
than quietly in someone's spreadsheet.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from like_spotify.extensions.google_sheets_storage import schema

REPO = Path(__file__).resolve().parents[1]
DART = REPO / "lib" / "data" / "likes" / "counter_sheet_schema.dart"
KOTLIN = (
    REPO
    / "android"
    / "app"
    / "src"
    / "main"
    / "kotlin"
    / "com"
    / "osasuwu"
    / "like_spotify"
    / "CounterSheetSchema.kt"
)

_QUOTED = re.compile(r"""['"]([^'"]*)['"]""")


def _declaration(source: str, name: str) -> str:
    """The text after ``name =``, up to the end of its declaration."""
    match = re.search(rf"\b{re.escape(name)}\b\s*=", source)
    if match is None:
        raise AssertionError(f"{name} is not declared any more")
    return source[match.end() :]


def _string(source: str, name: str) -> str:
    quoted = _QUOTED.search(_declaration(source, name))
    if quoted is None:
        raise AssertionError(f"{name} is no longer a string literal")
    return quoted.group(1)


def _string_list(source: str, name: str) -> list[str]:
    """The quoted items of a list literal — Dart ``[...]`` or Kotlin
    ``listOf(...)``."""
    tail = _declaration(source, name)
    opener = min(
        (index for index in (tail.find("["), tail.find("(")) if index != -1),
        default=-1,
    )
    if opener == -1:
        raise AssertionError(f"{name} is no longer a list literal")
    closer = {"[": "]", "(": ")"}[tail[opener]]
    end = tail.index(closer, opener)
    return _QUOTED.findall(tail[opener : end + 1])


@pytest.fixture(scope="module")
def dart() -> str:
    return DART.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def kotlin() -> str:
    return KOTLIN.read_text(encoding="utf-8")


def test_likes_tab_agrees_across_all_three_halves(dart: str, kotlin: str) -> None:
    assert schema.DEFAULT_SHEET == "Likes"
    assert _string(dart, "likesTab") == schema.DEFAULT_SHEET
    assert _string(kotlin, "LIKES_TAB") == schema.DEFAULT_SHEET


def test_likes_header_agrees_across_all_three_halves(dart: str, kotlin: str) -> None:
    assert schema.HEADER_ROW == [
        "user_id",
        "track_id",
        "count",
        "backfilled",
        "updated_at",
    ]
    assert _string_list(dart, "likesHeader") == schema.HEADER_ROW
    assert _string_list(kotlin, "LIKES_HEADER") == schema.HEADER_ROW


def test_artist_tab_agrees_across_all_three_halves(dart: str, kotlin: str) -> None:
    # Follow-artist records its triples here from the desktop, the phone's
    # foreground path and the background worker alike.
    assert schema.DEFAULT_ARTIST_SHEET == "ArtistTracks"
    assert schema.ARTIST_HEADER_ROW == [
        "user_id",
        "artist_id",
        "track_id",
        "created_at",
    ]
    assert _string(dart, "artistTracksTab") == schema.DEFAULT_ARTIST_SHEET
    assert _string_list(dart, "artistTracksHeader") == schema.ARTIST_HEADER_ROW
    assert _string(kotlin, "ARTIST_TRACKS_TAB") == schema.DEFAULT_ARTIST_SHEET
    assert _string_list(kotlin, "ARTIST_TRACKS_HEADER") == schema.ARTIST_HEADER_ROW


def test_new_spreadsheets_get_the_same_name_from_either_half(dart: str) -> None:
    assert _string(dart, "spreadsheetTitle") == schema.SPREADSHEET_TITLE


def test_written_columns_are_derived_from_the_header() -> None:
    # A reorder of HEADER_ROW must move the writes, not corrupt them.
    assert schema.COUNT_COLUMN == "C"
    assert schema.UPDATED_AT_COLUMN == "E"
    assert schema.column_of(["a", "b", "c"], "c") == "C"
    with pytest.raises(ValueError):
        schema.column_of(["a"], "missing")


def test_the_parser_would_notice_a_drift(dart: str) -> None:
    # Guards the test itself: a parse that quietly returned nothing would
    # make every assertion above vacuous.
    assert _string_list(dart, "likesHeader")
    with pytest.raises(AssertionError):
        _string(dart, "aConstantThatIsNotThere")
