package com.osasuwu.like_spotify

import com.osasuwu.like_spotify.UndoActionSync.Plan
import com.osasuwu.like_spotify.UndoActionSync.Tap
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * How the notification's Undo action follows the journal (#269): when it is
 * posted, when it comes down, when the service looks again, and what a tap
 * comes to. The journal's own answers are covered in [UndoJournalTest].
 */
class UndoActionSyncTest {

    private val window = UndoJournal.Window("press-1", closesAt = 63_000L)

    @Test
    fun `a window that opens posts the action and looks again just past its close`() {
        assertEquals(
            Plan(repost = true, offer = "press-1", recheckInMs = 8_001L),
            UndoActionSync.next(window, shown = null, now = 55_000L, halted = false),
        )
    }

    @Test
    fun `the same window again re-posts nothing and times the next look from now`() {
        assertEquals(
            Plan(repost = false, offer = "press-1", recheckInMs = 3_001L),
            UndoActionSync.next(window, shown = "press-1", now = 60_000L, halted = false),
        )
        // On the window's last, inclusive millisecond it is still open.
        assertEquals(
            Plan(repost = false, offer = "press-1", recheckInMs = 1L),
            UndoActionSync.next(window, shown = "press-1", now = 63_000L, halted = false),
        )
    }

    @Test
    fun `a newer like's window replaces the action offered for the old one`() {
        val newer = UndoJournal.Window("press-2", closesAt = 75_000L)
        assertEquals(
            Plan(repost = true, offer = "press-2", recheckInMs = 5_001L),
            UndoActionSync.next(newer, shown = "press-1", now = 70_000L, halted = false),
        )
    }

    @Test
    fun `once the window is gone the action comes down and nothing is looked at again`() {
        assertEquals(
            Plan(repost = true, offer = null, recheckInMs = null),
            UndoActionSync.next(null, shown = "press-1", now = 63_001L, halted = false),
        )
        assertEquals(
            Plan(repost = false, offer = null, recheckInMs = null),
            UndoActionSync.next(null, shown = null, now = 70_000L, halted = false),
        )
    }

    @Test
    fun `after Stop or while the service is destroyed nothing is posted or re-armed`() {
        assertEquals(
            Plan(repost = false, offer = null, recheckInMs = null),
            UndoActionSync.next(window, shown = null, now = 55_000L, halted = true),
        )
        assertEquals(
            Plan(repost = false, offer = "press-1", recheckInMs = null),
            UndoActionSync.next(null, shown = "press-1", now = 63_001L, halted = true),
        )
    }

    @Test
    fun `a tap the journal accepted runs the undo`() {
        assertEquals(Tap.UNDO, UndoActionSync.tap(accepted = true, tappedState = UndoJournal.State.UNDOING))
    }

    @Test
    fun `a tap on an undo already under way stays silent, as a repeat press does`() {
        assertEquals(Tap.ALREADY_UNDOING, UndoActionSync.tap(accepted = false, tappedState = UndoJournal.State.UNDOING))
    }

    @Test
    fun `a tap that came too late is told so`() {
        // The window passed, or a newer like took it over: the tapped like is still LIKED.
        assertEquals(Tap.TOO_LATE, UndoActionSync.tap(accepted = false, tappedState = UndoJournal.State.LIKED))
        assertEquals(Tap.TOO_LATE, UndoActionSync.tap(accepted = false, tappedState = UndoJournal.State.DONE))
        assertEquals(Tap.TOO_LATE, UndoActionSync.tap(accepted = false, tappedState = null))
    }

    // The tap both Undo surfaces run (#268): the notification action and the
    // in-app button. It is driven against the real journal, so what it starts
    // is what a repeat press inside the window would start.

    private val prefs = FakeSharedPreferences()
    private val started = mutableListOf<String>()
    private var tooLateCalls = 0

    /** A like with one leg that the worker finished at [likedAt]; its window closes 10 s later. */
    private fun likedAt(likedAt: Long): String {
        val id = UndoJournal.beginLike(prefs, likedAt)
        UndoJournal.setTrack(prefs, id, "trk-a", "spotify:track:trk-a")
        UndoJournal.recordLeg(prefs, id, UndoLeg.NativeSave(alreadySaved = false))
        assertEquals(UndoJournal.Finish.NONE, UndoJournal.finishLike(prefs, id, likedAt))
        return id
    }

    private fun tapAt(pressId: String?, now: Long): Tap =
        UndoActionSync.tap(prefs, pressId, now, startUndo = { started += it }, tooLate = { tooLateCalls++ })

    @Test
    fun `a tap inside the window marks the like undoing and starts the undo of that like`() {
        val id = likedAt(50_000L)

        assertEquals(Tap.UNDO, tapAt(id, now = 55_000L))
        assertEquals(listOf(id), started)
        assertEquals(0, tooLateCalls)
        assertEquals(UndoJournal.State.UNDOING, UndoJournal.entry(prefs, id)?.state)
    }

    @Test
    fun `a second tap while that undo is under way starts nothing and plays nothing`() {
        val id = likedAt(50_000L)
        tapAt(id, now = 55_000L)

        assertEquals(Tap.ALREADY_UNDOING, tapAt(id, now = 56_000L))
        assertEquals(listOf(id), started)
        assertEquals(0, tooLateCalls)
    }

    @Test
    fun `a tap after the window closed undoes nothing and is told so`() {
        val id = likedAt(50_000L)

        // The window closes at 60 000, inclusive.
        assertEquals(Tap.TOO_LATE, tapAt(id, now = 60_001L))
        assertEquals(emptyList<String>(), started)
        assertEquals(1, tooLateCalls)
        assertEquals(UndoJournal.State.LIKED, UndoJournal.entry(prefs, id)?.state)
    }

    @Test
    fun `a tap that names no like undoes nothing and is told so`() {
        val id = likedAt(50_000L)

        assertEquals(Tap.TOO_LATE, tapAt(null, now = 55_000L))
        assertEquals(emptyList<String>(), started)
        assertEquals(1, tooLateCalls)
        assertEquals(UndoJournal.State.LIKED, UndoJournal.entry(prefs, id)?.state)
    }

    @Test
    fun `the window crosses the platform channel as its press id and close time, and no window as null`() {
        // The keys are the contract with Dart's UndoWindow.fromChannel (#268).
        assertEquals(
            mapOf("pressId" to "press-1", "closesAt" to 63_000L),
            UndoActionSync.channelMap(window),
        )
        assertEquals(null, UndoActionSync.channelMap(null))
    }
}
