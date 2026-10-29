package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The order a trigger's YouTube Music like runs in (#274): the undo window
 * opens at the like's tone, so a repeat pressed during the like is answered
 * before the like is counted, and the like's own line is written before any
 * undo line about it.
 */
class YouTubeMusicLikeSequenceTest {

    /** Records every step; the window answers [undoneAtTone] the first time it opens. */
    private class Steps(
        private val undoneAtTone: Boolean = false,
        private val likeFails: Boolean = false,
    ) : YouTubeMusicLikeSequence.Steps<String> {
        val calls = mutableListOf<String>()
        private var opened = 0

        override fun like(): String {
            calls += "like"
            if (likeFails) throw IllegalStateException("no session")
            return "liked"
        }

        override fun tone(liked: String) {
            calls += "tone"
        }

        override fun openWindow(beforeUndoLine: () -> Unit): Boolean {
            calls += "open window"
            opened++
            if (opened == 1 && undoneAtTone) {
                // The undo writes its line through the report, which writes
                // the like's line first.
                beforeUndoLine()
                calls += "log undo"
                return true
            }
            return false
        }

        override fun count(liked: String): String {
            calls += "count"
            return "counted"
        }

        override fun extras(outcome: String) {
            calls += "extras"
        }

        override fun logLike(outcome: String) {
            calls += "log $outcome"
        }

        override fun failed(error: Exception) {
            calls += "failed"
        }
    }

    @Test
    fun `the undo window opens at the tone, before the like is counted`() {
        val steps = Steps()

        YouTubeMusicLikeSequence.run(steps)

        assertEquals(
            listOf("like", "tone", "open window", "count", "log counted", "extras", "open window"),
            steps.calls,
        )
    }

    @Test
    fun `a repeat during the like undoes it before it is counted, so it earns no counters or extras`() {
        val steps = Steps(undoneAtTone = true)

        YouTubeMusicLikeSequence.run(steps)

        assertEquals(listOf("like", "tone", "open window", "log liked", "log undo", "open window"), steps.calls)
    }

    @Test
    fun `an undone like writes its own line once, before the undo line about it`() {
        val steps = Steps(undoneAtTone = true)

        YouTubeMusicLikeSequence.run(steps)

        assertEquals(1, steps.calls.count { it == "log liked" })
        assertEquals(steps.calls.indexOf("log liked") + 1, steps.calls.indexOf("log undo"))
    }

    @Test
    fun `a like that throws still closes its press, so a repeat queued during it is answered`() {
        val steps = Steps(likeFails = true)

        YouTubeMusicLikeSequence.run(steps)

        assertEquals(listOf("like", "failed", "open window"), steps.calls)
    }
}
