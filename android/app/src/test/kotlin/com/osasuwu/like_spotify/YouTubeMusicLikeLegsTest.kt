package com.osasuwu.like_spotify

import com.osasuwu.like_spotify.YouTubeMusicLikeLegs.Session
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * What a YouTube Music like journals for its undo (#274), at the place the
 * like decides it: whether the rating was there before the press, which
 * session song or video the rating went to, and the playlist the like added
 * to. The undo reverts exactly these legs, so a wrong leg here is a wrong
 * undo, whatever the runner does with it.
 */
class YouTubeMusicLikeLegsTest {

    private val song = YouTubeMusicLiker.NowPlaying("Song", "Artist")
    private val key = YouTubeMusicLiker.cooldownKey("Song", "Artist")

    /** The account the like talks to: one video's rating, the calls it got. */
    private class Account(var rating: String = "none") {
        val calls = mutableListOf<String>()
        var ratingReadFails = false
        var ratingBody: String? = null

        fun call(method: String, url: String): String {
            val path = url.removePrefix(YouTubeDataApi.API_BASE)
            calls += "$method $path"
            return when {
                method == "GET" && path.startsWith("/videos/getRating") -> {
                    if (ratingReadFails) throw ApiFailure("quota exceeded", httpCode = 403)
                    ratingBody ?: """{"items":[{"videoId":"vid","rating":"$rating"}]}"""
                }
                method == "POST" && path.startsWith("/videos/rate") -> {
                    rating = path.substringAfter("rating=")
                    ""
                }
                else -> error("unexpected call $method $path")
            }
        }
    }

    private class Run(val account: Account, val journalling: Boolean) {
        val journal = mutableListOf<UndoLeg>()
        val legs = YouTubeMusicLikeLegs(
            journal = if (journalling) ({ leg -> journal += leg }) else null,
            apiCall = account::call,
            resolve = { YouTubeDataApi.Match("vid", "channel") },
            signedIn = { true },
            log = { _, _ -> },
            addToPlaylist = { _, _ -> YouTubeMusicExtraActions.PlaylistAdd("PL-like", itemId = "item-1") },
        )
    }

    private fun run(rating: String = "none", journalling: Boolean = true) = Run(Account(rating), journalling)

    @Test
    fun `a session like of a song already thumbed up journals the rating as the user's own`() {
        val run = run()

        val outcome = run.legs.native(Session.ALREADY_LIKED, song)

        assertEquals(YouTubeMusicLiker.Kind.ALREADY_LIKED, outcome.kind)
        assertEquals(listOf(UndoLeg.NativeSave(alreadySaved = true, sessionSong = key)), run.journal)
        assertEquals(emptyList<String>(), run.account.calls)
    }

    @Test
    fun `a session like journals the session song, so the undo takes the rating back there`() {
        val run = run()

        val outcome = run.legs.native(Session.LIKED, song)

        assertEquals(YouTubeMusicLiker.Kind.LIKED, outcome.kind)
        assertEquals(listOf(UndoLeg.NativeSave(alreadySaved = false, sessionSong = key)), run.journal)
    }

    @Test
    fun `a Data API like of an unrated video reads the rating before rating, and journals the video`() {
        val run = run(rating = "none")

        val outcome = run.legs.native(Session.DID_NOT_STICK, song)

        assertEquals(YouTubeMusicLiker.Kind.LIKED, outcome.kind)
        assertEquals(
            listOf("GET /videos/getRating?id=vid", "POST /videos/rate?id=vid&rating=like"),
            run.account.calls,
        )
        assertEquals(listOf(UndoLeg.NativeSave(alreadySaved = false, videoId = "vid")), run.journal)
    }

    @Test
    fun `a Data API like of a video the user had liked journals it as already rated`() {
        val run = run(rating = "like")

        run.legs.native(Session.UNSUPPORTED, song)

        assertEquals(listOf(UndoLeg.NativeSave(alreadySaved = true, videoId = "vid")), run.journal)
    }

    @Test
    fun `a Data API like of a video the user had disliked journals the dislike, so the undo puts it back`() {
        val run = run(rating = "dislike")

        run.legs.native(Session.UNSUPPORTED, song)

        assertEquals(listOf(UndoLeg.NativeSave(alreadySaved = false, videoId = "vid", disliked = true)), run.journal)
    }

    @Test
    fun `a rating that cannot be read journals the like as already rated, so the undo keeps it`() {
        val failing = run().apply { account.ratingReadFails = true }
        val unreadable = run().apply { account.ratingBody = """{"items":[]}""" }

        failing.legs.native(Session.UNSUPPORTED, song)
        unreadable.legs.native(Session.UNSUPPORTED, song)

        assertEquals(listOf(UndoLeg.NativeSave(alreadySaved = true, videoId = "vid")), failing.journal)
        assertEquals("like", failing.account.rating)
        assertEquals(listOf(UndoLeg.NativeSave(alreadySaved = true, videoId = "vid")), unreadable.journal)
    }

    @Test
    fun `a like that journals nothing spends no call on the rating before`() {
        val run = run(journalling = false)

        val outcome = run.legs.native(Session.UNSUPPORTED, song)

        assertEquals(YouTubeMusicLiker.Kind.LIKED, outcome.kind)
        assertEquals(listOf("POST /videos/rate?id=vid&rating=like"), run.account.calls)
        assertEquals(emptyList<UndoLeg>(), run.journal)
    }

    @Test
    fun `an add to the like playlist journals the playlist and the item it added`() {
        val run = run()

        val leg = run.legs.playlist(song, "Liked on the go")

        assertEquals(YouTubeMusicLiker.PlaylistLeg(true), leg)
        assertEquals(listOf(UndoLeg.LikePlaylistAdd("PL-like", itemId = "item-1")), run.journal)
    }
}
