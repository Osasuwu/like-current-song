package com.osasuwu.like_spotify

/**
 * The shape of the shared counter spreadsheet, in one place.
 *
 * Three halves write this same sheet — this file, the Dart repository
 * (`lib/data/likes/counter_sheet_schema.dart`) and the desktop storage
 * extension (`like_spotify/extensions/google_sheets_storage/schema.py`).
 * Until the app created the sheet itself a drift between them only cost a
 * confusing bug report; now the app types the header, so a drift means one
 * half appends rows another half will never find.
 * `tests/test_counter_schema_parity.py` fails the build if the three stop
 * agreeing.
 *
 * The spreadsheet's other tab, `ArtistTracks`, is desktop-only and is not
 * described here: the native counter never touches it.
 */
object CounterSheetSchema {
    /** The tab the per-track counts live on. */
    const val LIKES_TAB = "Likes"

    /** Row 1 of [LIKES_TAB]. Data starts at row 2. */
    val LIKES_HEADER = listOf(
        "user_id",
        "track_id",
        "count",
        "backfilled",
        "updated_at",
    )

    /**
     * The A1 column letter [header] keeps [column] in — so that reordering
     * the header moves the writes with it instead of quietly writing the
     * wrong cell.
     */
    fun columnOf(header: List<String>, column: String): String {
        val index = header.indexOf(column)
        require(index in 0..25) { "$column is not an A1 column of $header" }
        return ('A' + index).toString()
    }

    /** `count` on the [LIKES_TAB]. */
    val COUNT_COLUMN = columnOf(LIKES_HEADER, "count")

    /** `updated_at` on the [LIKES_TAB]. */
    val UPDATED_AT_COLUMN = columnOf(LIKES_HEADER, "updated_at")
}
