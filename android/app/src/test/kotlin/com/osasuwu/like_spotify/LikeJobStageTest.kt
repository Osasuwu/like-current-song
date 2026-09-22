package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

class LikeJobStageTest {

    @Test
    fun `a failure names the step it died in`() {
        val line = LikeJobStage.REFRESHING_TOKEN.failureLine(IOException("connection reset"))
        assertEquals(
            "Like failed while refreshing the Spotify token: IOException: connection reset",
            line,
        )
    }

    @Test
    fun `every stage reads differently on the logs screen`() {
        // The point of #191: one catch used to file every throw as a failed
        // like, so "the playlist add blew up" and "Google refused the refresh"
        // were the same line.
        val lines = LikeJobStage.values().map { it.failureLine(IOException("boom")) }
        assertEquals(lines.size, lines.toSet().size)
        val types = LikeJobStage.values().map { it.actionType }.toSet()
        assertTrue(types.contains("spotify_token_refresh"))
        assertTrue(types.contains("current_track"))
        assertTrue(types.contains("like_rules"))
    }

    @Test
    fun `a step after the like does not claim the like failed`() {
        val line = LikeJobStage.EXTRA_ACTIONS.failureLine(IllegalStateException("no playlist"))
        assertEquals(
            "The track was liked, but running the extra actions failed: " +
                "IllegalStateException: no playlist",
            line,
        )
        assertFalse(line.startsWith("Like failed"))
    }

    @Test
    fun `only the stages past the like say the like went through`() {
        assertFalse(LikeJobStage.STARTING.likeAlreadyDone)
        assertFalse(LikeJobStage.REFRESHING_TOKEN.likeAlreadyDone)
        assertFalse(LikeJobStage.READING_TRACK.likeAlreadyDone)
        assertFalse(LikeJobStage.LIKING.likeAlreadyDone)
        assertTrue(LikeJobStage.RECORDING_LIKE.likeAlreadyDone)
        assertTrue(LikeJobStage.EXTRA_ACTIONS.likeAlreadyDone)
    }

    @Test
    fun `a throwable with no message still says something`() {
        assertEquals(
            "Like failed while liking the track: NullPointerException: no message",
            LikeJobStage.LIKING.failureLine(NullPointerException()),
        )
    }
}
