package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The per-artist like count a background Spotify like raises, and the undo
 * leg that lowers it back (#281). The worker's artist loop is this pairing
 * plus the journal [ArtistLikeCounting.count] is handed.
 */
class ArtistLikeCountingTest {

    @Test
    fun `a like raises each artist's like count and hands the undo one leg per raise`() {
        val prefs = FakeSharedPreferences()
        val legs = mutableListOf<UndoLeg>()

        ArtistLikeCounting.count(prefs, "a1") { legs += it }
        ArtistLikeCounting.count(prefs, "a2") { legs += it }
        ArtistLikeCounting.count(prefs, "a1") { legs += it }

        assertEquals(mapOf("a1" to 2, "a2" to 1), LocalCounters.counts(prefs, LocalCounters.Kind.ARTIST))
        assertEquals(
            listOf(UndoLeg.ArtistLikeCount("a1"), UndoLeg.ArtistLikeCount("a2"), UndoLeg.ArtistLikeCount("a1")),
            legs,
        )
    }

    @Test
    fun `undoing the like's legs takes each artist like count back to before the press and leaves the track count alone`() {
        val prefs = FakeSharedPreferences()
        LocalCounters.increment(prefs, LocalCounters.Kind.ARTIST, "a1")
        LocalCounters.increment(prefs, LocalCounters.Kind.ARTIST, "a1")
        LocalCounters.increment(prefs, LocalCounters.Kind.TRACK, "a1")
        val before = LocalCounters.counts(prefs, LocalCounters.Kind.ARTIST)
        val legs = mutableListOf<UndoLeg>()

        ArtistLikeCounting.count(prefs, "a1") { legs += it }
        ArtistLikeCounting.count(prefs, "a2") { legs += it }
        legs.filterIsInstance<UndoLeg.ArtistLikeCount>().forEach { ArtistLikeCounting.undo(prefs, it.artistId) }

        assertEquals(before, LocalCounters.counts(prefs, LocalCounters.Kind.ARTIST))
        assertEquals(mapOf("a1" to 1), LocalCounters.counts(prefs, LocalCounters.Kind.TRACK))
    }
}
