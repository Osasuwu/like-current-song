package com.osasuwu.like_spotify

import com.osasuwu.like_spotify.YouTubeMusicLiker.Kind
import com.osasuwu.like_spotify.YouTubeMusicLiker.PlaylistLeg
import com.osasuwu.like_spotify.YouTubeMusicLiker.NowPlaying
import com.osasuwu.like_spotify.YouTubeMusicLiker.Outcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What a YouTube Music like adds up to once the legs the destination asked
 * for have run. The legs themselves talk to the media session and the Data
 * API, so only this join is reachable from a plain JUnit test — which is why
 * it is a pure function rather than inline branching.
 */
class YouTubeMusicLikerCombineTest {

    private val song = NowPlaying(title = "Test Song", artist = "Artist One")

    private fun liked() = Outcome(Kind.LIKED, song.display, nowPlaying = song)

    private fun failedNative(error: String = "session refused") =
        Outcome(Kind.FAILED, song.display, error = error, httpCode = 403, nowPlaying = song)

    private fun combine(
        destination: LikeDestination,
        native: Outcome? = null,
        playlist: PlaylistLeg? = null,
    ) = YouTubeMusicLiker.combine(destination, song, "Trigger likes", native, playlist)

    // ---- one-leg destinations ---------------------------------------------

    @Test
    fun `liked songs reports the native leg alone`() {
        val outcome = combine(LikeDestination.NATIVE, native = liked())

        assertEquals(Kind.LIKED, outcome.kind)
        assertTrue(outcome.likedNatively)
        assertFalse(outcome.addedToLikePlaylist)
        assertNull(outcome.partialFailure)
    }

    @Test
    fun `a failed native leg fails a liked-songs like`() {
        val outcome = combine(LikeDestination.NATIVE, native = failedNative())

        assertEquals(Kind.FAILED, outcome.kind)
        assertEquals("session refused", outcome.error)
        assertEquals(403, outcome.httpCode)
    }

    @Test
    fun `a playlist destination reports the playlist leg alone`() {
        val outcome = combine(LikeDestination.PLAYLIST, playlist = PlaylistLeg(added = true))

        assertEquals(Kind.LIKED, outcome.kind)
        assertFalse(outcome.likedNatively)
        assertTrue(outcome.addedToLikePlaylist)
        assertNull(outcome.partialFailure)
    }

    @Test
    fun `a failed playlist leg fails a playlist like`() {
        val outcome = combine(
            LikeDestination.PLAYLIST,
            playlist = PlaylistLeg(added = false, error = "quota exceeded", httpCode = 403),
        )

        assertEquals(Kind.FAILED, outcome.kind)
        assertEquals("quota exceeded", outcome.error)
        assertEquals(403, outcome.httpCode)
    }

    // ---- both --------------------------------------------------------------

    @Test
    fun `both reports two successful legs`() {
        val outcome = combine(
            LikeDestination.BOTH,
            native = liked(),
            playlist = PlaylistLeg(added = true),
        )

        assertEquals(Kind.LIKED, outcome.kind)
        assertTrue(outcome.likedNatively)
        assertTrue(outcome.addedToLikePlaylist)
        assertNull(outcome.partialFailure)
    }

    @Test
    fun `a half-failed both like still counts and names the failed leg`() {
        val outcome = combine(
            LikeDestination.BOTH,
            native = failedNative(),
            playlist = PlaylistLeg(added = true),
        )

        assertTrue(outcome.positive)
        assertFalse(outcome.likedNatively)
        assertTrue(outcome.addedToLikePlaylist)
        val partial = outcome.partialFailure ?: error("the failed leg must be reported")
        assertTrue(partial, partial.startsWith("Liked songs failed"))
        assertTrue(partial, partial.contains("Trigger likes"))
        assertTrue(partial, partial.contains("session refused"))
    }

    @Test
    fun `a failed playlist leg still counts and names itself`() {
        val outcome = combine(
            LikeDestination.BOTH,
            native = liked(),
            playlist = PlaylistLeg(added = false, error = "quota exceeded", httpCode = 403),
        )

        assertTrue(outcome.positive)
        assertTrue(outcome.likedNatively)
        assertFalse(outcome.addedToLikePlaylist)
        val partial = outcome.partialFailure ?: error("the failed leg must be reported")
        assertTrue(partial, partial.startsWith("Adding to \"Trigger likes\""))
        assertTrue(partial, partial.contains("quota exceeded"))
    }

    @Test
    fun `both fails only when both legs fail`() {
        val outcome = combine(
            LikeDestination.BOTH,
            native = failedNative(),
            playlist = PlaylistLeg(added = false, error = "quota exceeded", httpCode = 403),
        )

        assertEquals(Kind.FAILED, outcome.kind)
        // The native error is the one the user can act on.
        assertEquals("session refused", outcome.error)
    }

    // ---- already liked -----------------------------------------------------

    @Test
    fun `an already liked song with nothing else to do stays already liked`() {
        val already = Outcome(Kind.ALREADY_LIKED, song.display, nowPlaying = song)

        assertEquals(Kind.ALREADY_LIKED, combine(LikeDestination.NATIVE, native = already).kind)
    }

    @Test
    fun `an already liked song that reached the playlist is a fresh like`() {
        // Nothing changed in liked songs, but the playlist gained the song, so
        // the like did do something and the log line should say so.
        val already = Outcome(Kind.ALREADY_LIKED, song.display, nowPlaying = song)

        val outcome = combine(
            LikeDestination.BOTH,
            native = already,
            playlist = PlaylistLeg(added = true),
        )

        assertEquals(Kind.LIKED, outcome.kind)
        assertTrue(outcome.addedToLikePlaylist)
    }

    // ---- the detached log line ---------------------------------------------

    @Test
    fun `the detached log line carries the half that failed`() {
        // With no Flutter UI attached this single line is all the user gets.
        val outcome = combine(
            LikeDestination.BOTH,
            native = failedNative(),
            playlist = PlaylistLeg(added = true),
        )

        val line = outcome.logLine()
        assertTrue(line, line.startsWith("Liked: Test Song — Artist One"))
        assertTrue(line, line.contains("Liked songs failed"))
    }

    @Test
    fun `a like with nothing to report keeps its plain log line`() {
        val line = combine(LikeDestination.NATIVE, native = liked()).logLine()

        assertEquals("Liked: Test Song — Artist One", line)
    }

    // ---- what the channel hands Dart ---------------------------------------

    @Test
    fun `the channel map carries both legs and the partial failure`() {
        val outcome = combine(
            LikeDestination.BOTH,
            native = liked(),
            playlist = PlaylistLeg(added = false, error = "quota exceeded"),
        )

        val map = outcome.toChannelMap()
        assertEquals("liked", map["outcome"])
        assertEquals(true, map["likedNatively"])
        assertEquals(false, map["addedToLikePlaylist"])
        assertTrue((map["partialFailure"] as String).contains("Trigger likes"))
    }

    // ---- the shared playlist add -------------------------------------------

    @Test
    fun `the like's playlist leg is logged apart from the best-playlist rule`() {
        // Both go through YouTubeMusicExtraActions.addToPlaylist, so only the
        // action type tells the two apart on the Logs screen.
        assertEquals("like_playlist_add", YouTubeMusicExtraActions.LIKE_PLAYLIST_ACTION)
    }
}
