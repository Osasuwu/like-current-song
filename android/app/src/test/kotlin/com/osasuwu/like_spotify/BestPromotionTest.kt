package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The best-playlist decision the Spotify worker makes (#245). The worker
 * itself needs an Android runtime and the network; the rule, the membership
 * gate and the remember-only-on-success bookkeeping are all in here.
 */
class BestPromotionTest {

    private val prefs = FakeSharedPreferences()
    private val asked = mutableListOf<String>()

    private fun promote(
        count: Int,
        threshold: Int = 3,
        key: String = "trk-a",
        inPlaylist: Boolean = false,
        added: () -> Boolean = { true },
    ) = BestPromotion.run(
        prefs,
        count,
        threshold,
        key,
        isInPlaylist = { asked += "membership"; inPlaylist },
        add = { asked += "add"; added() },
    )

    @Test
    fun `short of the threshold nothing is asked of the service`() {
        assertEquals(BestPromotion.Outcome.NOT_DUE, promote(count = 2))
        assertEquals(emptyList<String>(), asked)
    }

    @Test
    fun `on the threshold the track is checked, added and remembered`() {
        assertEquals(BestPromotion.Outcome.ADDED, promote(count = 3))
        assertEquals(listOf("membership", "add"), asked)
        assertEquals(setOf("trk-a"), LocalCounters.promotedTracks(prefs))
    }

    @Test
    fun `a count past the threshold still promotes`() {
        assertEquals(BestPromotion.Outcome.ADDED, promote(count = 9))
    }

    @Test
    fun `a promoted track is not promoted again, and the service is not asked`() {
        promote(count = 3)
        asked.clear()
        assertEquals(BestPromotion.Outcome.NOT_DUE, promote(count = 4))
        assertEquals(BestPromotion.Outcome.NOT_DUE, promote(count = 50))
        assertEquals(emptyList<String>(), asked)
    }

    @Test
    fun `a track already in the playlist is remembered without an add`() {
        assertEquals(BestPromotion.Outcome.ALREADY_IN_PLAYLIST, promote(count = 5, inPlaylist = true))
        assertEquals(listOf("membership"), asked)
        assertEquals(setOf("trk-a"), LocalCounters.promotedTracks(prefs))
    }

    @Test
    fun `an add the service did not take is not remembered, so the next like retries`() {
        assertEquals(BestPromotion.Outcome.NOT_ADDED, promote(count = 3, added = { false }))
        assertEquals(emptySet<String>(), LocalCounters.promotedTracks(prefs))
        assertEquals(BestPromotion.Outcome.ADDED, promote(count = 4))
    }

    @Test
    fun `an add that threw is not remembered`() {
        assertThrows(IllegalStateException::class.java) {
            promote(count = 3, added = { throw IllegalStateException("HTTP 503") })
        }
        assertEquals(emptySet<String>(), LocalCounters.promotedTracks(prefs))
    }

    @Test
    fun `the memory is per track`() {
        promote(count = 3, key = "trk-a")
        assertEquals(BestPromotion.Outcome.ADDED, promote(count = 3, key = "trk-b"))
        assertEquals(setOf("trk-a", "trk-b"), LocalCounters.promotedTracks(prefs))
    }

    @Test
    fun `the memory is stored under its own key, apart from the followed artists`() {
        promote(count = 3)
        assertTrue(prefs.values.containsKey(AppConstants.KEY_PROMOTED_TRACKS))
        assertFalse(prefs.values.containsKey(AppConstants.KEY_FOLLOWED_ARTISTS))
    }

    @Test
    fun `only a promotion the run made is left for an undo to revert`() {
        // #273: a press that found the track in best already, or did not get
        // it in, changed nothing there, so its undo must not take it out.
        val legs = BestPromotion.Outcome.values().associateWith { BestPromotion.undoLeg(it, "pl-best") }

        assertEquals(
            mapOf(
                BestPromotion.Outcome.NOT_DUE to null,
                BestPromotion.Outcome.ALREADY_IN_PLAYLIST to null,
                BestPromotion.Outcome.ADDED to UndoLeg.BestPromote("pl-best"),
                BestPromotion.Outcome.NOT_ADDED to null,
            ),
            legs,
        )
    }
}
