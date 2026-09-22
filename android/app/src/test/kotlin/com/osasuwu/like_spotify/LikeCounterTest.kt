package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LikeCounterTest {

    // ---- userIdFor -------------------------------------------------

    @Test
    fun `spotify likes are keyed by the spotify user id`() {
        assertEquals(
            "spotify-user",
            LikeCounter.userIdFor(MusicProvider.SPOTIFY, spotifyUserId = "spotify-user", ytmUserSub = "google-sub"),
        )
    }

    @Test
    fun `youtube music likes are keyed by the google sub`() {
        assertEquals(
            "google-sub",
            LikeCounter.userIdFor(MusicProvider.YTMUSIC, spotifyUserId = "spotify-user", ytmUserSub = "google-sub"),
        )
    }

    @Test
    fun `no fallback to the other service's id`() {
        assertNull(LikeCounter.userIdFor(MusicProvider.YTMUSIC, spotifyUserId = "spotify-user", ytmUserSub = null))
        assertNull(LikeCounter.userIdFor(MusicProvider.SPOTIFY, spotifyUserId = null, ytmUserSub = "google-sub"))
    }

    @Test
    fun `a blank id means not signed in`() {
        assertNull(LikeCounter.userIdFor(MusicProvider.YTMUSIC, spotifyUserId = null, ytmUserSub = "  "))
        assertNull(LikeCounter.userIdFor(MusicProvider.SPOTIFY, spotifyUserId = "", ytmUserSub = null))
    }

    // ---- findRow -------------------------------------------------

    @Test
    fun `finds the row of a user and track pair, skipping the header`() {
        val body = """
            {"values":[
              ["user_id","track_id","count","backfilled","updated_at"],
              ["other","t1","4","FALSE","2026-01-01T00:00:00Z"],
              ["google-sub","dQw4w9WgXcQ","7","FALSE","2026-01-02T00:00:00Z"]
            ]}
        """.trimIndent()
        // Header, then two data rows: the pair sits on sheet row 3.
        assertEquals(3 to 7, LikeCounter.findRow(body, "google-sub", "dQw4w9WgXcQ"))
    }

    @Test
    fun `a header row that happens to match is never returned`() {
        val body = """{"values":[["u","t","count","FALSE","now"],["u","t","2","FALSE","now"]]}"""
        assertEquals(2 to 2, LikeCounter.findRow(body, "u", "t"))
    }

    @Test
    fun `an unreadable or empty sheet has no row`() {
        assertNull(LikeCounter.findRow(null, "u", "t"))
        assertNull(LikeCounter.findRow("", "u", "t"))
        assertNull(LikeCounter.findRow("""{"range":"Likes!A1:E1"}""", "u", "t"))
        assertNull(LikeCounter.findRow("""{"values":[["user_id","track_id"]]}""", "u", "t"))
    }

    @Test
    fun `a pair with two rows resolves to the topmost one`() {
        // Sheets damaged before #193 carry duplicates. Whichever half counts
        // the next like has to pick the same row, or the two counts drift
        // further apart every press; the rule is "topmost wins".
        val body = """
            {"values":[
              ["user_id","track_id","count","backfilled","updated_at"],
              ["u","t",1,"FALSE","2026-01-01T00:00:00Z"],
              ["u","t",1,"FALSE","2026-01-02T00:00:00Z"]
            ]}
        """.trimIndent()
        assertEquals(2 to 1, LikeCounter.findRow(body, "u", "t"))
    }

    @Test
    fun `a row whose count is missing or junk counts as zero`() {
        val body = """{"values":[["user_id","track_id","count"],["u","t",""],["x","y","nope"]]}"""
        assertEquals(2 to 0, LikeCounter.findRow(body, "u", "t"))
        assertEquals(3 to 0, LikeCounter.findRow(body, "x", "y"))
    }

    // ---- rowFromA1Range -------------------------------------------------

    @Test
    fun `reads the row an append landed on`() {
        assertEquals(12, LikeCounter.rowFromA1Range("Likes!A12:E12"))
        assertEquals(2, LikeCounter.rowFromA1Range("Likes!A2:E2"))
    }

    @Test
    fun `a missing range is no row`() {
        assertNull(LikeCounter.rowFromA1Range(null))
        assertNull(LikeCounter.rowFromA1Range(""))
        assertNull(LikeCounter.rowFromA1Range("Likes"))
    }

    // ---- writeBody -------------------------------------------------

    @Test
    fun `a count goes out as a number, not as text`() {
        // Every write is RAW, so a count sent as "1" lands on the sheet as
        // text beside the numbers the Dart half writes into the same column.
        assertEquals("""{"values":[[3]]}""", LikeCounter.writeBody(listOf(3)))
    }

    @Test
    fun `an appended row keeps a number a number and text text`() {
        val body = LikeCounter.writeBody(
            listOf("google-sub", "dQw4w9WgXcQ", 1, "FALSE", "2026-01-02T00:00:00Z"),
        )
        assertEquals(
            """{"values":[["google-sub","dQw4w9WgXcQ",1,"FALSE","2026-01-02T00:00:00Z"]]}""",
            body,
        )
    }

    @Test
    fun `a timestamp is still written as text`() {
        assertEquals("""{"values":[["2026-01-02T00:00:00Z"]]}""", LikeCounter.writeBody(listOf("2026-01-02T00:00:00Z")))
    }

    // ---- nowIso -------------------------------------------------

    @Test
    fun `timestamps match the shape the desktop writes`() {
        assertTrue(LikeCounter.nowIso().matches(Regex("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z")))
    }
}
