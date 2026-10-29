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
    private val youTubeMusicLikes = mutableListOf<String>()
    private val spotifyUndos = mutableListOf<String>()
    private val youTubeMusicUndos = mutableListOf<String>()

    private fun trigger(prefs: FakeSharedPreferences, provider: MusicProvider, afterUndo: Boolean = false) =
        TriggerLike.run(
            prefs,
            provider,
            now = 50_000L,
            afterUndo = afterUndo,
            likeOnSpotify = { pressId, after -> spotifyLikes += pressId to after },
            likeOnYouTubeMusic = { pressId -> youTubeMusicLikes += pressId },
        )

    private fun undo(prefs: FakeSharedPreferences, pressId: String) =
        TriggerLike.undo(
            prefs,
            pressId,
            undoOnSpotify = { spotifyUndos += it },
            undoOnYouTubeMusic = { youTubeMusicUndos += it },
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
        assertEquals(0, youTubeMusicLikes.size)
    }

    @Test
    fun `with the app closed a Spotify trigger goes the same way`() {
        val prefs = FakeSharedPreferences()

        trigger(prefs, MusicProvider.SPOTIFY)

        assertEquals(1, spotifyLikes.size)
        val (pressId, afterUndo) = spotifyLikes.single()
        assertEquals(false, afterUndo)
        assertEquals(UndoJournal.State.LIKING, UndoJournal.entry(prefs, pressId)?.state)
        assertEquals(0, youTubeMusicLikes.size)
    }

    @Test
    fun `a YouTube Music trigger is journaled as a YouTube Music like and handed to the liker`() {
        FlutterAttachment.attached = true
        val prefs = FakeSharedPreferences()

        trigger(prefs, MusicProvider.YTMUSIC)

        assertEquals(0, spotifyLikes.size)
        val pressId = youTubeMusicLikes.single()
        val entry = UndoJournal.entry(prefs, pressId)
        assertEquals(UndoJournal.State.LIKING, entry?.state)
        assertEquals(MusicProvider.YTMUSIC, entry?.provider)
    }

    @Test
    fun `a repeat of a YouTube Music like is undone by YouTube Music`() {
        val prefs = FakeSharedPreferences()
        trigger(prefs, MusicProvider.YTMUSIC)
        val pressId = youTubeMusicLikes.single()

        undo(prefs, pressId)

        assertEquals(listOf(pressId), youTubeMusicUndos)
        assertEquals(emptyList<String>(), spotifyUndos)
    }

    @Test
    fun `a repeat of a Spotify like, or of a like no longer journaled, is undone by Spotify`() {
        val prefs = FakeSharedPreferences()
        trigger(prefs, MusicProvider.SPOTIFY)
        val pressId = spotifyLikes.single().first

        undo(prefs, pressId)
        undo(prefs, "gone")

        // Spotify's undo is the one that logs a like no longer in the journal.
        assertEquals(listOf(pressId, "gone"), spotifyUndos)
        assertEquals(emptyList<String>(), youTubeMusicUndos)
    }

    @Test
    fun `a like journaled before providers were recorded is a Spotify like`() {
        val prefs = FakeSharedPreferences()
        prefs.values[AppConstants.KEY_UNDO_JOURNAL] =
            """[{"id":"old","state":"LIKED","likedAt":1,"legs":[]}]"""

        assertEquals(MusicProvider.SPOTIFY, UndoJournal.entry(prefs, "old")?.provider)
    }
}
