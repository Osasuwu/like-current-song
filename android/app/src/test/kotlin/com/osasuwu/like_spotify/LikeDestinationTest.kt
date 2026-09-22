package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The destination branching both native like paths run on: `SpotifyLikeWorker`
 * asks [LikeDestination.likesNatively] / [LikeDestination.addsToPlaylist] which
 * legs to send and [LikeDestination.succeeded] whether the like counted, and
 * `YouTubeMusicLiker` asks exactly the same questions. The two paths cannot
 * drift while every decision lives here.
 *
 * The Kotlin twin of `test/domain/entities/like_destination_test.dart`; the
 * two files mirror each other on purpose.
 */
class LikeDestinationTest {

    // ---- which legs run ---------------------------------------------------

    @Test
    fun `liked songs likes natively only`() {
        assertTrue(LikeDestination.NATIVE.likesNatively)
        assertFalse(LikeDestination.NATIVE.addsToPlaylist)
    }

    @Test
    fun `a playlist adds to the playlist only`() {
        assertFalse(LikeDestination.PLAYLIST.likesNatively)
        assertTrue(LikeDestination.PLAYLIST.addsToPlaylist)
    }

    @Test
    fun `both does both`() {
        assertTrue(LikeDestination.BOTH.likesNatively)
        assertTrue(LikeDestination.BOTH.addsToPlaylist)
    }

    // ---- fromId -----------------------------------------------------------

    @Test
    fun `every id Dart writes reads back unchanged`() {
        // The ids are the Dart enum's, written into SharedPreferences by the
        // setRuleConfig channel call.
        assertEquals(LikeDestination.NATIVE, LikeDestination.fromId("native"))
        assertEquals(LikeDestination.PLAYLIST, LikeDestination.fromId("playlist"))
        assertEquals(LikeDestination.BOTH, LikeDestination.fromId("both"))
    }

    @Test
    fun `a missing or unknown id keeps the behaviour the app always had`() {
        assertEquals(LikeDestination.NATIVE, LikeDestination.DEFAULT)
        assertEquals(LikeDestination.DEFAULT, LikeDestination.fromId(null))
        assertEquals(LikeDestination.DEFAULT, LikeDestination.fromId(""))
        assertEquals(LikeDestination.DEFAULT, LikeDestination.fromId("somewhere-new"))
    }

    // ---- resolve ----------------------------------------------------------

    @Test
    fun `a named playlist destination is kept`() {
        assertEquals(LikeDestination.PLAYLIST, LikeDestination.resolve("playlist", "Trigger likes"))
        assertEquals(LikeDestination.BOTH, LikeDestination.resolve("both", "Trigger likes"))
    }

    @Test
    fun `a nameless playlist destination degrades to liked songs`() {
        // Nowhere to put the song: like it the old way rather than fail.
        assertEquals(LikeDestination.NATIVE, LikeDestination.resolve("playlist", ""))
        assertEquals(LikeDestination.NATIVE, LikeDestination.resolve("both", "   "))
    }

    @Test
    fun `liked songs ignores the playlist name`() {
        assertEquals(LikeDestination.NATIVE, LikeDestination.resolve("native", ""))
        assertEquals(LikeDestination.NATIVE, LikeDestination.resolve("native", "Trigger likes"))
    }

    // ---- succeeded --------------------------------------------------------

    @Test
    fun `a one-leg destination is exactly as good as its leg`() {
        assertTrue(LikeDestination.succeeded(LikeDestination.NATIVE, nativeOk = true, playlistOk = false))
        assertFalse(LikeDestination.succeeded(LikeDestination.NATIVE, nativeOk = false, playlistOk = true))
        assertTrue(LikeDestination.succeeded(LikeDestination.PLAYLIST, nativeOk = false, playlistOk = true))
        assertFalse(LikeDestination.succeeded(LikeDestination.PLAYLIST, nativeOk = true, playlistOk = false))
    }

    @Test
    fun `both fails only when both legs fail`() {
        assertTrue(LikeDestination.succeeded(LikeDestination.BOTH, nativeOk = true, playlistOk = true))
        assertTrue(LikeDestination.succeeded(LikeDestination.BOTH, nativeOk = true, playlistOk = false))
        assertTrue(LikeDestination.succeeded(LikeDestination.BOTH, nativeOk = false, playlistOk = true))
        assertFalse(LikeDestination.succeeded(LikeDestination.BOTH, nativeOk = false, playlistOk = false))
    }
}
