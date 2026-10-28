package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Which counter a background like is counted on, and which one the undo is
 * told to lower (#272). The worker's track counter is this choice plus the
 * HTTP and prefs calls [TrackCounting.Ops] stands for.
 */
class TrackCountingTest {

    private val sheet = LikeCounter.Target(spreadsheetId = "sheet-1", userId = "user-1")

    private class Counters(
        val target: LikeCounter.Target?,
        val sheetAnswer: (LikeCounter.Target) -> LikeCounter.CountOutcome = { LikeCounter.CountOutcome.counted(5) },
        val targetThrows: Boolean = false,
        val journalThrows: Boolean = false,
    ) : TrackCounting.Ops {
        var local = 0
        val sheetCalls = mutableListOf<LikeCounter.Target>()
        val journalled = mutableListOf<UndoLeg.TrackCount>()
        val refused = mutableListOf<LikeCounter.CountOutcome>()

        override fun target(): LikeCounter.Target? {
            if (targetThrows) throw IllegalStateException("no Spotify user id")
            return target
        }

        override fun incrementSheet(target: LikeCounter.Target): LikeCounter.CountOutcome {
            sheetCalls += target
            return sheetAnswer(target)
        }

        override fun incrementLocal(): Int = ++local

        override fun journal(leg: UndoLeg.TrackCount) {
            if (journalThrows) throw IllegalStateException("journal unwritable")
            journalled += leg
        }

        override fun sheetRefused(outcome: LikeCounter.CountOutcome) {
            refused += outcome
        }
    }

    @Test
    fun `a like the sheet counted is journalled against that sheet and not counted on this device`() {
        val counters = Counters(target = sheet)

        assertEquals(5, TrackCounting.count(counters))
        assertEquals(listOf(UndoLeg.TrackCount(sheet)), counters.journalled)
        assertEquals(0, counters.local)
        assertEquals(emptyList<LikeCounter.CountOutcome>(), counters.refused)
    }

    @Test
    fun `a like the sheet refused is counted on this device, journalled against it, and the refusal reported`() {
        val refusal = LikeCounter.CountOutcome.failed("the counter sheet refused the new count", 503)
        val counters = Counters(target = sheet, sheetAnswer = { refusal })

        assertEquals(1, TrackCounting.count(counters))
        assertEquals(listOf(UndoLeg.TrackCount(sheet = null)), counters.journalled)
        assertEquals(1, counters.local)
        assertEquals(listOf(refusal), counters.refused)
    }

    @Test
    fun `with no sheet configured the like is counted on this device and journalled against it`() {
        val counters = Counters(target = null)

        assertEquals(1, TrackCounting.count(counters))
        assertEquals(listOf(UndoLeg.TrackCount(sheet = null)), counters.journalled)
        assertEquals(emptyList<LikeCounter.Target>(), counters.sheetCalls)
        assertEquals(emptyList<LikeCounter.CountOutcome>(), counters.refused)
    }

    @Test
    fun `a sheet lookup or count that throws leaves the like counted once, on this device`() {
        val lookupThrows = Counters(target = sheet, targetThrows = true)
        val countThrows = Counters(target = sheet, sheetAnswer = { throw java.io.IOException("reset") })

        for (counters in listOf(lookupThrows, countThrows)) {
            assertEquals(1, TrackCounting.count(counters))
            assertEquals(1, counters.local)
            assertEquals(listOf(UndoLeg.TrackCount(sheet = null)), counters.journalled)
        }
    }

    @Test
    fun `a journal that cannot be written does not count the like a second time`() {
        val onSheet = Counters(target = sheet, journalThrows = true)
        val onDevice = Counters(target = null, journalThrows = true)

        assertEquals(5, TrackCounting.count(onSheet))
        assertEquals(0, onSheet.local)
        assertEquals(1, TrackCounting.count(onDevice))
        assertEquals(1, onDevice.local)
    }
}
