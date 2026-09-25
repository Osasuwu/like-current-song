package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    // ---- artistTrackTally -------------------------------------------------

    private val artistTab = """
        {"values":[
          ["user_id","artist_id","track_id","created_at"],
          ["me","artist-a","t1","2026-01-01T00:00:00Z"],
          ["me","artist-a","t2","2026-01-02T00:00:00Z"],
          ["me","artist-b","t3","2026-01-03T00:00:00Z"],
          ["someone-else","artist-a","t4","2026-01-04T00:00:00Z"]
        ]}
    """.trimIndent()

    @Test
    fun `a new track is unseen and counts the artist's other tracks`() {
        // The caller appends it and answers count + 1.
        assertEquals(false to 2, LikeCounter.artistTrackTally(artistTab, "me", "artist-a", "t9"))
    }

    @Test
    fun `a track liked again is seen and does not move the number`() {
        assertEquals(true to 2, LikeCounter.artistTrackTally(artistTab, "me", "artist-a", "t1"))
    }

    @Test
    fun `rows the desktop wrote count on the phone`() {
        // Nothing in a row says which device wrote it: a desktop YouTube Music
        // like is keyed by the same Google sub and bare channel id.
        val body = """
            {"values":[
              ["user_id","artist_id","track_id","created_at"],
              ["google-sub","UCchannel","vid1","2026-01-01T00:00:00Z"]
            ]}
        """.trimIndent()
        assertEquals(false to 1, LikeCounter.artistTrackTally(body, "google-sub", "UCchannel", "vid2"))
    }

    @Test
    fun `a triple written twice counts once`() {
        val body = """{"values":[["h","h","h","h"],["me","a","t1","x"],["me","a","t1","y"]]}"""
        assertEquals(false to 1, LikeCounter.artistTrackTally(body, "me", "a", "t2"))
    }

    @Test
    fun `the header and short rows are skipped`() {
        val body = """{"values":[["me","a","t1","created_at"],["me","a"],["me","a","t2"]]}"""
        assertEquals(false to 1, LikeCounter.artistTrackTally(body, "me", "a", "t1"))
    }

    @Test
    fun `other users and other artists do not count`() {
        assertEquals(false to 1, LikeCounter.artistTrackTally(artistTab, "me", "artist-b", "t9"))
        assertEquals(false to 1, LikeCounter.artistTrackTally(artistTab, "someone-else", "artist-a", "t9"))
    }

    @Test
    fun `an empty tab or an unreadable body counts nothing`() {
        assertEquals(false to 0, LikeCounter.artistTrackTally("{}", "me", "a", "t1"))
        assertEquals(false to 0, LikeCounter.artistTrackTally("not json", "me", "a", "t1"))
        assertEquals(false to 0, LikeCounter.artistTrackTally(null, "me", "a", "t1"))
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

    // ---- tokenRefusedMessage -------------------------------------------------

    private fun refused(error: String?, httpCode: Int?, needsReauth: Boolean = true) =
        LikeCounter.tokenRefusedMessage(
            GoogleTokens.RefreshFailure("refused", httpCode, needsReauth, error),
        )

    @Test
    fun `a rejected client is not a sign-in problem`() {
        // #200: `invalid_client` needs the credentials fixing under Connected
        // services. Telling the user to sign in again sends them round a loop
        // that cannot end, because signing in uses the same rejected client.
        val message = refused("invalid_client", httpCode = 401)
        assertTrue(message.contains("invalid_client"))
        assertTrue(message.contains("client ID or secret"))
        assertFalse(message.contains("Sign in again"))
    }

    @Test
    fun `an unauthorized client reads the same way`() {
        assertTrue(refused("unauthorized_client", httpCode = 401).contains("client ID or secret"))
    }

    @Test
    fun `a revoked sign-in does say to sign in again`() {
        val message = refused("invalid_grant", httpCode = 400)
        assertTrue(message.contains("Sign in again"))
        assertFalse(message.contains("client ID or secret"))
    }

    @Test
    fun `a refused scope names the scope`() {
        assertTrue(refused("invalid_scope", httpCode = 400).contains("invalid_scope"))
    }

    @Test
    fun `a request that never went out means nobody signed the counter in`() {
        // No status: `refresh` threw before opening a connection, because the
        // client id or the refresh token is missing.
        val message = refused(null, httpCode = null)
        assertTrue(message.contains("not signed in to Google"))
    }

    @Test
    fun `a refusal google did not explain still carries its status`() {
        assertTrue(refused(null, httpCode = 503, needsReauth = false).contains("503"))
    }

    @Test
    fun `no two refusals read the same`() {
        val messages = listOf(
            refused("invalid_client", 401),
            refused("invalid_grant", 400),
            refused("invalid_scope", 400),
            refused(null, null),
            refused(null, 503, needsReauth = false),
        )
        assertEquals(messages.size, messages.toSet().size)
    }
}
