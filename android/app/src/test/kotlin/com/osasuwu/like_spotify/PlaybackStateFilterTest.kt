package com.osasuwu.like_spotify

import android.media.session.PlaybackState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Which session states reach the trigger as `play` / `pause` (#248).
 *
 * An automatic pause and resume — another app taking audio focus, a session
 * stopping and restarting — must not produce the `pause, play` a user's
 * gesture does. Only a real STATE_PAUSED counts as a pause.
 */
class PlaybackStateFilterTest {

    @Test
    fun `playing is a play and paused is a pause`() {
        val filter = PlaybackStateFilter()

        assertEquals("play", filter.onState("s1", PlaybackState.STATE_PLAYING))
        assertEquals("pause", filter.onState("s1", PlaybackState.STATE_PAUSED))
    }

    @Test
    fun `stopped and none are not a pause`() {
        val filter = PlaybackStateFilter()
        filter.onState("s1", PlaybackState.STATE_PLAYING)

        assertNull(filter.onState("s1", PlaybackState.STATE_STOPPED))
        assertNull(filter.onState("s1", PlaybackState.STATE_NONE))
    }

    @Test
    fun `a stop and restart does not read as pause then play`() {
        // The resume after an interruption often passes through STOPPED or
        // NONE; counted as a pause, it completed the default pattern.
        val filter = PlaybackStateFilter()
        val events = listOf(
            PlaybackState.STATE_PLAYING,
            PlaybackState.STATE_STOPPED,
            PlaybackState.STATE_NONE,
            PlaybackState.STATE_BUFFERING,
            PlaybackState.STATE_PLAYING,
        ).mapNotNull { filter.onState("s1", it) }

        assertEquals(listOf("play"), events)
    }

    @Test
    fun `a repeated state is reported once`() {
        val filter = PlaybackStateFilter()

        assertEquals("pause", filter.onState("s1", PlaybackState.STATE_PAUSED))
        assertNull(filter.onState("s1", PlaybackState.STATE_PAUSED))
    }

    @Test
    fun `two sessions of one app keep their own memory`() {
        // Spotify can hold several sessions. Shared per package, a second
        // session's pause made the first one's repeated PLAYING look new, and
        // that pair was a like.
        val filter = PlaybackStateFilter()
        val events = listOf(
            "main" to PlaybackState.STATE_PLAYING,
            "other" to PlaybackState.STATE_PAUSED,
            "main" to PlaybackState.STATE_PLAYING,
        ).mapNotNull { (session, state) -> filter.onState(session, state) }

        assertEquals(listOf("play", "pause"), events)
    }
}
