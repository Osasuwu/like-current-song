package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [BackgroundLog.emit] needs an Android runtime, but the line it writes does
 * not -- so the formatting and the redaction are tested here, where the suite
 * is plain JUnit with no Robolectric.
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
}
