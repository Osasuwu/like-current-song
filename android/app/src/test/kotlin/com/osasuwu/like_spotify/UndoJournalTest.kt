package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The undo gesture's bookkeeping (#267): which press likes, which undoes, and
 * what the undo may revert. The service and the worker never share memory
 * they can rely on, so every test reads the journal back through the same
 * [FakeSharedPreferences] the way the other side of the hand-off would.
 *
 * The 10 s window is the contract: it was fixed by the decision #267 cites.
 */
class UndoJournalTest {

    private val prefs = FakeSharedPreferences()

    /** A like the worker finished at [likedAt], having performed [legs]. */
    private fun likedAt(likedAt: Long, vararg legs: UndoLeg, pressedAt: Long = likedAt): String {
        val id = UndoJournal.beginLike(prefs, pressedAt)
        UndoJournal.setTrack(prefs, id, "trk-a", "spotify:track:trk-a")
        legs.forEach { UndoJournal.recordLeg(prefs, id, it) }
        assertEquals(UndoJournal.Finish.NONE, UndoJournal.finishLike(prefs, id, likedAt))
        return id
    }

    @Test
    fun `with nothing in the journal a press likes`() {
        assertEquals(UndoJournal.Press.Like(afterUndo = false), UndoJournal.onPress(prefs, 1_000L))
    }

    @Test
    fun `a press within 10 s of a finished like undoes it and the next reader sees the undo started`() {
        val id = likedAt(50_000L, UndoLeg.NativeSave(alreadySaved = false))

        assertEquals(UndoJournal.Press.Undo(id), UndoJournal.onPress(prefs, 55_000L))
        assertEquals(UndoJournal.State.UNDOING, UndoJournal.entry(prefs, id)?.state)
    }

    @Test
    fun `the window is 10 s from the like's tone, inclusive`() {
        val id = likedAt(likedAt = 53_000L, UndoLeg.NativeSave(alreadySaved = false), pressedAt = 50_000L)

        assertEquals(UndoJournal.Press.Undo(id), UndoJournal.onPress(prefs, 63_000L))
    }

    @Test
    fun `a press 1 ms past the window likes again`() {
        likedAt(likedAt = 53_000L, UndoLeg.NativeSave(alreadySaved = false), pressedAt = 50_000L)

        assertEquals(UndoJournal.Press.Like(afterUndo = false), UndoJournal.onPress(prefs, 63_001L))
    }

    @Test
    fun `a press timed before the like, after a clock change, likes`() {
        likedAt(50_000L, UndoLeg.NativeSave(alreadySaved = false))

        assertEquals(UndoJournal.Press.Like(afterUndo = false), UndoJournal.onPress(prefs, 49_000L))
    }

    @Test
    fun `the recorded legs and track come back to the undo in the order they were performed`() {
        val legs = arrayOf(
            UndoLeg.NativeSave(alreadySaved = true),
            UndoLeg.LikePlaylistAdd(playlistId = "pl-like"),
            UndoLeg.ArchiveRemove(playlistId = "pl-arch", copies = 2),
        )
        val id = likedAt(50_000L, *legs)

        val entry = UndoJournal.entry(prefs, id)!!
        assertEquals("trk-a", entry.trackId)
        assertEquals("spotify:track:trk-a", entry.trackUri)
        assertEquals(legs.toList(), entry.legs)
    }

    @Test
    fun `a cooldown stamp comes back with the stamp it replaced, or with none`() {
        val legs = arrayOf(UndoLeg.CooldownStamp(previous = 1_234L), UndoLeg.CooldownStamp(previous = null))
        val id = likedAt(50_000L, *legs)

        assertEquals(legs.toList(), UndoJournal.entry(prefs, id)!!.legs)
    }

    @Test
    fun `a repeat mid-like is queued once, runs when the like finishes, and a third press is ignored`() {
        val id = UndoJournal.beginLike(prefs, 50_000L)

        assertEquals(UndoJournal.Press.QueueUndo, UndoJournal.onPress(prefs, 52_000L))
        assertEquals(UndoJournal.Press.Ignore, UndoJournal.onPress(prefs, 53_000L))

        UndoJournal.recordLeg(prefs, id, UndoLeg.NativeSave(alreadySaved = false))
        assertEquals(UndoJournal.Finish.RUN_UNDO, UndoJournal.finishLike(prefs, id, 54_000L))
        assertEquals(UndoJournal.State.UNDOING, UndoJournal.entry(prefs, id)?.state)
        assertEquals(UndoJournal.Press.Ignore, UndoJournal.onPress(prefs, 55_000L))
    }

    @Test
    fun `a like that performed nothing leaves a queued undo nothing to do and closes`() {
        val id = UndoJournal.beginLike(prefs, 50_000L)
        UndoJournal.onPress(prefs, 51_000L)

        assertEquals(UndoJournal.Finish.UNDO_NOTHING, UndoJournal.finishLike(prefs, id, 52_000L))
        assertEquals(UndoJournal.Press.Like(afterUndo = false), UndoJournal.onPress(prefs, 53_000L))
    }

    @Test
    fun `a like that performed nothing opens no window`() {
        likedAt(50_000L)

        assertEquals(UndoJournal.Press.Like(afterUndo = false), UndoJournal.onPress(prefs, 51_000L))
    }

    @Test
    fun `a like still pending 10 s after its press is replaced by the next press`() {
        UndoJournal.beginLike(prefs, 50_000L)

        assertEquals(UndoJournal.Press.Like(afterUndo = false), UndoJournal.onPress(prefs, 60_001L))
    }

    @Test
    fun `after an undo finishes the window is closed and the next press likes`() {
        val id = likedAt(50_000L, UndoLeg.NativeSave(alreadySaved = false))
        UndoJournal.onPress(prefs, 52_000L)
        UndoJournal.finishUndo(prefs, id)

        assertEquals(UndoJournal.Press.Like(afterUndo = false), UndoJournal.onPress(prefs, 53_000L))
    }

    @Test
    fun `a press during a running undo is ignored, and once its window is past it likes after the undo`() {
        val id = likedAt(50_000L, UndoLeg.NativeSave(alreadySaved = false))
        UndoJournal.onPress(prefs, 52_000L)

        assertEquals(UndoJournal.Press.Ignore, UndoJournal.onPress(prefs, 55_000L))
        assertEquals(UndoJournal.Press.Like(afterUndo = true), UndoJournal.onPress(prefs, 60_001L))
        assertEquals(UndoJournal.State.UNDOING, UndoJournal.entry(prefs, id)?.state)
    }

    @Test
    fun `a superseded like's late bookkeeping does not move the latest like`() {
        val old = UndoJournal.beginLike(prefs, 50_000L)
        val current = likedAt(61_000L, UndoLeg.NativeSave(alreadySaved = false))

        UndoJournal.recordLeg(prefs, old, UndoLeg.LikePlaylistAdd("pl-like"))
        UndoJournal.finishLike(prefs, old, 62_000L)

        assertEquals(UndoJournal.Press.Undo(current), UndoJournal.onPress(prefs, 63_000L))
        assertEquals(listOf(UndoLeg.NativeSave(alreadySaved = false)), UndoJournal.entry(prefs, current)?.legs)
    }

    // The notification's Undo action (#269): shown while the window is open,
    // and a tap on it starts the same undo a repeat of the trigger would.

    @Test
    fun `a finished like opens a window for the notification that closes 10 s after its tone`() {
        val id = likedAt(likedAt = 53_000L, UndoLeg.NativeSave(alreadySaved = false), pressedAt = 50_000L)

        assertEquals(UndoJournal.Window(id, closesAt = 63_000L), UndoJournal.openWindow(prefs, 55_000L))
        assertEquals(UndoJournal.Window(id, closesAt = 63_000L), UndoJournal.openWindow(prefs, 63_000L))
        assertNull(UndoJournal.openWindow(prefs, 63_001L))
    }

    @Test
    fun `there is no window while the like runs, for a like that performed nothing, or after a clock change`() {
        val running = UndoJournal.beginLike(prefs, 50_000L)
        assertNull(UndoJournal.openWindow(prefs, 51_000L))

        UndoJournal.finishLike(prefs, running, 52_000L)
        assertNull(UndoJournal.openWindow(prefs, 53_000L))

        likedAt(60_000L, UndoLeg.NativeSave(alreadySaved = false))
        assertNull(UndoJournal.openWindow(prefs, 59_000L))
    }

    @Test
    fun `the window closes as soon as an undo starts, through any surface, and stays closed once it is done`() {
        val byPress = likedAt(50_000L, UndoLeg.NativeSave(alreadySaved = false))
        UndoJournal.onPress(prefs, 52_000L)
        assertNull(UndoJournal.openWindow(prefs, 52_000L))
        UndoJournal.finishUndo(prefs, byPress)
        assertNull(UndoJournal.openWindow(prefs, 53_000L))

        val byTap = likedAt(70_000L, UndoLeg.NativeSave(alreadySaved = false))
        UndoJournal.requestUndo(prefs, byTap, 71_000L)
        assertNull(UndoJournal.openWindow(prefs, 71_000L))
    }

    @Test
    fun `a tap inside the window starts the undo the way a repeat press does`() {
        val id = likedAt(50_000L, UndoLeg.NativeSave(alreadySaved = false))

        assertTrue(UndoJournal.requestUndo(prefs, id, 55_000L))
        assertEquals(UndoJournal.State.UNDOING, UndoJournal.entry(prefs, id)?.state)
        // The repeat press that follows sees the undo already in hand.
        assertEquals(UndoJournal.Press.Ignore, UndoJournal.onPress(prefs, 56_000L))
    }

    @Test
    fun `a tap on a stale Undo starts nothing`() {
        val id = likedAt(50_000L, UndoLeg.NativeSave(alreadySaved = false))

        // Past the window: the action outlived it on screen.
        assertFalse(UndoJournal.requestUndo(prefs, id, 60_001L))
        assertEquals(UndoJournal.State.LIKED, UndoJournal.entry(prefs, id)?.state)

        // A newer like took over the window: the old action must not undo it.
        val newer = likedAt(61_000L, UndoLeg.NativeSave(alreadySaved = false))
        assertFalse(UndoJournal.requestUndo(prefs, id, 62_000L))
        assertEquals(UndoJournal.State.LIKED, UndoJournal.entry(prefs, newer)?.state)

        // The gesture already started the undo: a tap does not start a second.
        UndoJournal.onPress(prefs, 63_000L)
        assertFalse(UndoJournal.requestUndo(prefs, newer, 63_500L))
    }

    @Test
    fun `an unreadable journal reads as empty and a press likes`() {
        prefs.values[AppConstants.KEY_UNDO_JOURNAL] = "{not json"

        assertEquals(UndoJournal.Press.Like(afterUndo = false), UndoJournal.onPress(prefs, 1_000L))
    }
}
