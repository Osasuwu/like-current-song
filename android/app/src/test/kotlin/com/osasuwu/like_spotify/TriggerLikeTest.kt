package com.osasuwu.like_spotify

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A trigger's like goes the same way with the app open as in the background
 * (#268), so it is journaled and a repeat can undo it either way.
 */
class TriggerLikeTest {

    private val spotifyLikes = mutableListOf<Pair<String, Boolean>>()
    private var youTubeMusicLikes = 0

    private fun trigger(prefs: FakeSharedPreferences, provider: MusicProvider, afterUndo: Boolean = false) =
        TriggerLike.run(
            prefs,
            provider,
            now = 50_000L,
            afterUndo = afterUndo,
            likeOnSpotify = { pressId, after -> spotifyLikes += pressId to after },
            likeOnYouTubeMusic = { youTubeMusicLikes++ },
        )

    @After
    fun closeTheApp() {
        FlutterAttachment.attached = false
    }

    @Test
    fun `with the app open a Spotify trigger is journaled and handed to the worker`() {
        FlutterAttachment.attached = true
        val prefs = FakeSharedPreferences()

        trigger(prefs, MusicProvider.SPOTIFY, afterUndo = true)

        assertEquals(1, spotifyLikes.size)
        val (pressId, afterUndo) = spotifyLikes.single()
        assertEquals(true, afterUndo)
        // The worker's like is the journal's latest entry, so a repeat finds it.
        assertEquals(UndoJournal.State.LIKING, UndoJournal.entry(prefs, pressId)?.state)
        assertEquals(0, youTubeMusicLikes)
    }

    @Test
    fun `with the app closed a Spotify trigger goes the same way`() {
        val prefs = FakeSharedPreferences()

        trigger(prefs, MusicProvider.SPOTIFY)

        assertEquals(1, spotifyLikes.size)
        val (pressId, afterUndo) = spotifyLikes.single()
        assertEquals(false, afterUndo)
        assertEquals(UndoJournal.State.LIKING, UndoJournal.entry(prefs, pressId)?.state)
        assertEquals(0, youTubeMusicLikes)
    }

    @Test
    fun `with the app open a YouTube Music trigger likes in-process and journals nothing`() {
        FlutterAttachment.attached = true
        val prefs = FakeSharedPreferences()

        trigger(prefs, MusicProvider.YTMUSIC)

        assertEquals(1, youTubeMusicLikes)
        assertEquals(0, spotifyLikes.size)
        assertEquals(null, prefs.values[AppConstants.KEY_UNDO_JOURNAL])
    }
}
