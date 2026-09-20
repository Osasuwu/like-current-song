"""The shape of the shared counter spreadsheet, in one place.

Three halves write this same sheet — this file, the Dart repository
(``lib/data/likes/counter_sheet_schema.dart``) and the native counter
(``android/.../CounterSheetSchema.kt``). Until the app created the sheet
itself a drift between them only cost a confusing bug report; now the app
types the header, so a drift means one half appends rows another half will
never find. ``tests/test_counter_schema_parity.py`` fails the build if the
three stop agreeing.
"""

from __future__ import annotations

#: The title a freshly created spreadsheet gets in the user's Drive.
SPREADSHEET_TITLE = "Like Current Song counters"

#: The tab the per-track counts live on.
DEFAULT_SHEET = "Likes"

#: The tab the (user, artist, track) triples live on. Desktop-only, but the
#: phone creates it too: one spreadsheet is meant to serve both halves.
DEFAULT_ARTIST_SHEET = "ArtistTracks"

#: Row 1 of :data:`DEFAULT_SHEET`. Data starts at row 2.
HEADER_ROW = ["user_id", "track_id", "count", "backfilled", "updated_at"]

#: Row 1 of :data:`DEFAULT_ARTIST_SHEET`.
ARTIST_HEADER_ROW = ["user_id", "artist_id", "track_id", "created_at"]


def column_of(header: list[str], column: str) -> str:
    """The A1 column letter *header* keeps *column* in.

    Derived rather than written down, so that reordering the header moves
    the writes with it instead of quietly writing the wrong cell.
    """
    try:
        index = header.index(column)
    except ValueError:
        raise ValueError(f"{column!r} is not a column of {header!r}") from None
    if index > 25:
        raise ValueError(f"{column!r} is past column Z of {header!r}")
    return chr(ord("A") + index)


#: ``count`` on :data:`DEFAULT_SHEET`.
COUNT_COLUMN = column_of(HEADER_ROW, "count")

#: ``updated_at`` on :data:`DEFAULT_SHEET`.
UPDATED_AT_COLUMN = column_of(HEADER_ROW, "updated_at")


def _tab(title: str, header: list[str]) -> dict:
    return {
        "properties": {"title": title},
        "data": [
            {
                "startRow": 0,
                "startColumn": 0,
                "rowData": [
                    {
                        "values": [
                            {"userEnteredValue": {"stringValue": cell}}
                            for cell in header
                        ]
                    }
                ],
            }
        ],
    }


def create_request_body() -> dict:
    """The body of ``POST /v4/spreadsheets``: title, both tabs, both headers.

    One call makes the whole thing, so there is no half-made spreadsheet to
    clean up when it fails.
    """
    return {
        "properties": {"title": SPREADSHEET_TITLE},
        "sheets": [
            _tab(DEFAULT_SHEET, HEADER_ROW),
            _tab(DEFAULT_ARTIST_SHEET, ARTIST_HEADER_ROW),
        ],
    }
