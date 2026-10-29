package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * How a YouTube Music like closes its journal entry and how its undo is
 * reported (#274): the same lines and tones a Spotify undo gives.
 */
class UndoCompletionTest {

    private class Heard : UndoCompletion.Report {
        val lines = mutableListOf<Triple<String, String, String?>>()
        val tones = mutableListOf<FeedbackKind>()
        override fun log(message: String, result: String, targetId: String?) {
            lines += Triple(message, result, targetId)
        }
        override fun tone(kind: FeedbackKind) {
            tones += kind
        }
    }

    private val song = YouTubeMusicLiker.cooldownKey("Song", "Artist")

    /** API calls that all fail, as a dropped connection would make them. */
    private val apiDown: (String, String, String?) -> String = { _, _, _ ->
        throw ApiFailure("YouTube Data API unavailable", 503)
    }

    /**
     * A like of "vid" that stamped the cooldown (first liked at 500) and,
     * when [withPlaylist], added it to the like playlist. Still liking.
     */
    private fun liking(prefs: FakeSharedPreferences, withPlaylist: Boolean = false): String {
        val id = UndoJournal.beginLike(prefs, now = 1_000L, provider = MusicProvider.YTMUSIC)
        UndoJournal.setTrack(prefs, id, "vid", "vid")
        if (withPlaylist) UndoJournal.recordLeg(prefs, id, UndoLeg.LikePlaylistAdd("PLlike"))
        UndoJournal.recordLeg(prefs, id, UndoLeg.CooldownStamp(500L, key = song))
        LocalCounters.recordLikedAt(prefs, song, 1_000L)
        return id
    }

    private fun ops(prefs: FakeSharedPreferences) = YouTubeMusicUndoOps(prefs, apiDown)

    @Test
    fun `a like no repeat came in for closes without an undo and opens the window`() {
        val prefs = FakeSharedPreferences()
        val id = liking(prefs)
        val heard = Heard()

        val undone = UndoCompletion.closeLike(prefs, id, likedAt = 2_000L, report = heard) { ops(prefs) }

        assertEquals(false, undone)
        assertEquals(emptyList<FeedbackKind>(), heard.tones)
        assertEquals(1_000L, LocalCounters.lastLikedAt(prefs, song))
        assertEquals(UndoJournal.Press.Undo(id), UndoJournal.onPress(prefs, now = 2_000L + UndoJournal.WINDOW_MS))
    }

    @Test
    fun `a repeat during the like gives one undo when the like closes, and the next press likes`() {
        val prefs = FakeSharedPreferences()
        val id = liking(prefs)
        assertEquals(UndoJournal.Press.QueueUndo, UndoJournal.onPress(prefs, now = 1_500L))
        val heard = Heard()

        val undone = UndoCompletion.closeLike(prefs, id, likedAt = 2_000L, report = heard) { ops(prefs) }

        assertEquals(true, undone)
        assertEquals(500L, LocalCounters.lastLikedAt(prefs, song))
        assertEquals(listOf(Triple("Undid like of vid: cooldown stamp", "success", "vid")), heard.lines)
        assertEquals(listOf(FeedbackKind.UNDO), heard.tones)
        assertEquals(UndoJournal.Press.Like(afterUndo = false), UndoJournal.onPress(prefs, now = 2_500L))
    }

    @Test
    fun `a repeat during a like that did nothing says so and plays the undo tone`() {
        val prefs = FakeSharedPreferences()
        val id = UndoJournal.beginLike(prefs, now = 1_000L, provider = MusicProvider.YTMUSIC)
        UndoJournal.onPress(prefs, now = 1_500L)
        val heard = Heard()

        val undone = UndoCompletion.closeLike(prefs, id, likedAt = 2_000L, report = heard) { ops(prefs) }

        assertEquals(true, undone)
        assertEquals(listOf(Triple("Undo: the like had nothing to revert", "info", null)), heard.lines)
        assertEquals(listOf(FeedbackKind.UNDO), heard.tones)
    }

    @Test
    fun `an undo with a failed leg reverts the others, names the leg and plays the error tone`() {
        val prefs = FakeSharedPreferences()
        val id = liking(prefs, withPlaylist = true)
        UndoJournal.finishLike(prefs, id, now = 2_000L)
        val heard = Heard()

        UndoCompletion.undo(prefs, id, heard) { ops(prefs) }

        assertEquals(500L, LocalCounters.lastLikedAt(prefs, song))
        val (message, result, target) = heard.lines.single()
        assertTrue(message, message.startsWith("Undo failed on like playlist ("))
        assertTrue(message, message.contains("YouTube Data API unavailable"))
        assertEquals("failure" to "vid", result to target)
        assertEquals(listOf(FeedbackKind.ERROR), heard.tones)
        assertEquals(UndoJournal.Press.Like(afterUndo = false), UndoJournal.onPress(prefs, now = 2_500L))
    }

    @Test
    fun `an undo that names no like is skipped with the error tone`() {
        val heard = Heard()

        UndoCompletion.undo(FakeSharedPreferences(), null, heard) { error("not reached") }

        assertEquals(listOf(Triple("Undo skipped: no like to undo was named", "failure", null)), heard.lines)
        assertEquals(listOf(FeedbackKind.ERROR), heard.tones)
    }

    @Test
    fun `an undo of a like no longer journalled fails with the error tone`() {
        val heard = Heard()

        UndoCompletion.undo(FakeSharedPreferences(), "gone", heard) { error("not reached") }

        assertEquals(listOf(Triple("Undo failed: the like is no longer in the journal", "failure", null)), heard.lines)
        assertEquals(listOf(FeedbackKind.ERROR), heard.tones)
    }

    @Test
    fun `an undo that throws is reported, and the next press likes again`() {
        val prefs = FakeSharedPreferences()
        val id = liking(prefs)
        UndoJournal.finishLike(prefs, id, now = 2_000L)
        UndoJournal.onPress(prefs, now = 2_500L)
        val heard = Heard()

        UndoCompletion.undo(prefs, id, heard) { throw IllegalStateException("no YouTube account") }

        assertEquals(
            listOf(Triple("Undo failed: IllegalStateException: no YouTube account", "failure", null)),
            heard.lines,
        )
        assertEquals(listOf(FeedbackKind.ERROR), heard.tones)
        assertEquals(UndoJournal.Press.Like(afterUndo = false), UndoJournal.onPress(prefs, now = 3_000L))
    }
}
