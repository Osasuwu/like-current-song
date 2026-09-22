package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [BackgroundLog.emit] needs an Android runtime, but neither the line it writes
 * nor the buffer entry it stores does -- so the formatting, the redaction and
 * the JSON shaping are tested here, where the suite is plain JUnit with no
 * Robolectric. Only the SharedPreferences shell around them is left untested.
 */
class BackgroundLogTest {

    @Test
    fun `formats action type and result as a prefix`() {
        assertEquals(
            "[like_track/success] Liked track: 4cOdK2wGLETKBW3PvgPWqT",
            BackgroundLog.format(
                message = "Liked track: 4cOdK2wGLETKBW3PvgPWqT",
                actionType = "like_track",
                result = "success",
            )
        )
    }

    @Test
    fun `appends target and http code when present`() {
        assertEquals(
            "[like_playlist_add/failure] Adding to like playlist failed: Liked target=abc http=403",
            BackgroundLog.format(
                message = "Adding to like playlist failed: Liked",
                actionType = "like_playlist_add",
                result = "failure",
                targetId = "abc",
                httpCode = 403,
            )
        )
    }

    @Test
    fun `omits target and http code when absent`() {
        val line = BackgroundLog.format("Worker started", "native", "info")
        assertEquals("[native/info] Worker started", line)
    }

    @Test
    fun `redacts anything long enough to be a credential`() {
        val token = "BQC" + "x".repeat(180)
        val line = BackgroundLog.format("refresh returned $token", "native", "info")
        assertTrue("token must not survive: $line", !line.contains(token))
        assertEquals("[native/info] refresh returned <redacted>", line)
    }

    @Test
    fun `leaves real identifiers alone`() {
        // Spotify ids are 22 characters, YouTube video ids 11 -- both well
        // under the redaction threshold, and both things we need to read.
        val spotifyId = "4cOdK2wGLETKBW3PvgPWqT"
        val youTubeId = "dQw4w9WgXcQ"
        assertEquals("Liked $spotifyId", BackgroundLog.redact("Liked $spotifyId"))
        assertEquals("Liked $youTubeId", BackgroundLog.redact("Liked $youTubeId"))
    }

    @Test
    fun `redacts a credential embedded in a longer sentence`() {
        val line = BackgroundLog.redact("Bearer ${"a".repeat(64)} rejected")
        assertEquals("Bearer <redacted> rejected", line)
    }

    // ---- The buffer ----------------------------------------------

    @Test
    fun `encodes every field Dart reads`() {
        val entry = BackgroundLog.encodeEntry(
            atMs = 1_700_000_000_000L,
            message = "Added to like playlist: Liked",
            actionType = "like_playlist_add",
            result = "success",
            targetId = "4cOdK2wGLETKBW3PvgPWqT",
            httpCode = 201,
        )
        assertEquals(1_700_000_000_000L, entry.getLong("atMs"))
        assertEquals("like_playlist_add", entry.getString("actionType"))
        assertEquals("success", entry.getString("result"))
        assertEquals("Added to like playlist: Liked", entry.getString("message"))
        assertEquals("4cOdK2wGLETKBW3PvgPWqT", entry.getString("targetId"))
        assertEquals(201, entry.getInt("httpCode"))
    }

    @Test
    fun `leaves out an absent target and http code instead of writing null`() {
        val entry = BackgroundLog.encodeEntry(1L, "Worker started", "native", "info")
        assertTrue(!entry.has("targetId"))
        assertTrue(!entry.has("httpCode"))
    }

    @Test
    fun `redacts on the way into the buffer, not only into logcat`() {
        val token = "BQC" + "x".repeat(180)
        val entry = BackgroundLog.encodeEntry(1L, "refresh returned $token", "native", "info")
        assertEquals("refresh returned <redacted>", entry.getString("message"))
    }

    @Test
    fun `appends in order and keeps the newest when full`() {
        var stored = "[]"
        repeat(5) { i ->
            stored = BackgroundLog
                .appendBounded(stored, BackgroundLog.encodeEntry(i.toLong(), "e$i", "native", "info"), max = 3)
                .toString()
        }
        val entries = BackgroundLog.decodeEntries(stored)
        // Oldest first, and the two oldest of the five are gone.
        assertEquals(listOf("e2", "e3", "e4"), entries.map { it["message"] })
    }

    @Test
    fun `a corrupt buffer is treated as empty rather than losing the new event`() {
        val kept = BackgroundLog.appendBounded(
            "{not json at all",
            BackgroundLog.encodeEntry(1L, "survivor", "native", "info"),
            max = 200,
        )
        assertEquals(1, kept.length())
        assertEquals("survivor", kept.getJSONObject(0).getString("message"))
    }

    @Test
    fun `an absent buffer decodes to nothing`() {
        assertEquals(emptyList<Map<String, Any>>(), BackgroundLog.decodeEntries(null))
        assertEquals(emptyList<Map<String, Any>>(), BackgroundLog.decodeEntries("[]"))
        assertEquals(emptyList<Map<String, Any>>(), BackgroundLog.decodeEntries("garbage"))
    }

    @Test
    fun `decodes an entry written by an older build with fields missing`() {
        val entries = BackgroundLog.decodeEntries("""[{"message":"half a line"}]""")
        assertEquals(1, entries.size)
        val entry = entries.single()
        assertEquals("half a line", entry["message"])
        // The defaults match what the Dart `AppLog` falls back to.
        assertEquals("legacy", entry["actionType"])
        assertEquals("info", entry["result"])
        assertEquals(0L, entry["atMs"])
        assertTrue(!entry.containsKey("targetId"))
        assertTrue(!entry.containsKey("httpCode"))
    }

    @Test
    fun `skips an entry that is not an object and keeps the rest`() {
        val entries = BackgroundLog.decodeEntries("""["junk",{"message":"real","atMs":7}]""")
        assertEquals(listOf("real"), entries.map { it["message"] })
        assertEquals(7L, entries.single()["atMs"])
    }
}
