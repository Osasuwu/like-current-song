package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [LocalCounters] keeps its JSON shaping separate from the SharedPreferences
 * shell exactly so the shaping can be tested here, where the suite is plain
 * JUnit with no Robolectric. The counting, the merge rule and the degradation
 * on unreadable storage all live in the pure half; only the shell is untested.
 */
class LocalCountersTest {

    // ---- Kind.fromId -------------------------------------------------

    @Test
    fun `the two kinds map to their own stores`() {
        assertEquals(LocalCounters.Kind.TRACK, LocalCounters.Kind.fromId("track"))
        assertEquals(LocalCounters.Kind.ARTIST, LocalCounters.Kind.fromId("artist"))
        assertEquals(AppConstants.KEY_TRACK_LIKE_COUNTS, LocalCounters.Kind.TRACK.prefsKey)
        assertEquals(AppConstants.KEY_ARTIST_LIKE_COUNTS, LocalCounters.Kind.ARTIST.prefsKey)
    }

    @Test
    fun `an unknown kind is not guessed at`() {
        assertNull(LocalCounters.Kind.fromId("album"))
        assertNull(LocalCounters.Kind.fromId(""))
        assertNull(LocalCounters.Kind.fromId(null))
    }

    // ---- parseCounts / encode -------------------------------------------------

    @Test
    fun `counts survive a round trip through storage`() {
        val counts = mapOf("t1" to 3, "t2" to 1)
        assertEquals(counts, LocalCounters.parseCounts(LocalCounters.encode(counts)))
    }

    @Test
    fun `nothing stored yet reads as no counts`() {
        assertEquals(emptyMap<String, Int>(), LocalCounters.parseCounts(null))
    }

    @Test
    fun `unreadable stored counts degrade to empty instead of throwing`() {
        assertEquals(emptyMap<String, Int>(), LocalCounters.parseCounts("{\"t1\":2"))
        assertEquals(emptyMap<String, Int>(), LocalCounters.parseCounts("[1,2,3]"))
        assertEquals(emptyMap<String, Int>(), LocalCounters.parseCounts(""))
    }

    // ---- incremented -------------------------------------------------

    @Test
    fun `a track counted for the first time lands on one`() {
        assertEquals(mapOf("t1" to 1), LocalCounters.incremented(null, "t1"))
        assertEquals(mapOf("t1" to 1), LocalCounters.incremented("{}", "t1"))
    }

    @Test
    fun `a track counted before goes one higher`() {
        assertEquals(mapOf("t1" to 5), LocalCounters.incremented("""{"t1":4}""", "t1"))
    }

    @Test
    fun `counting one id leaves the others alone`() {
        val updated = LocalCounters.incremented("""{"t1":4,"t2":9}""", "t1")
        assertEquals(mapOf("t1" to 5, "t2" to 9), updated)
    }

    // ---- parseTimestamps -------------------------------------------------

    @Test
    fun `timestamps survive a round trip at millisecond width`() {
        // Past Int range on purpose: epoch millis overflow a 32-bit count.
        val stamps = mapOf("t1" to 1_758_499_200_000L)
        assertEquals(stamps, LocalCounters.parseTimestamps(LocalCounters.encode(stamps)))
    }

    @Test
    fun `unreadable stored timestamps degrade to empty instead of throwing`() {
        assertEquals(emptyMap<String, Long>(), LocalCounters.parseTimestamps("not json at all"))
    }

    // ---- summed -------------------------------------------------

    @Test
    fun `likes counted in the two old stores add up`() {
        // The whole point of the migration: three likes in the app and two on
        // the media button were five likes, counted into stores that could not
        // see each other. Keeping the larger would throw two of them away.
        assertEquals(
            mapOf("t1" to 5),
            LocalCounters.summed(existing = mapOf("t1" to 2), incoming = mapOf("t1" to 3)),
        )
    }

    @Test
    fun `an id only one store ever saw arrives at its own count`() {
        assertEquals(
            mapOf("t1" to 7, "t2" to 4),
            LocalCounters.summed(existing = mapOf("t1" to 7), incoming = mapOf("t2" to 4)),
        )
    }

    @Test
    fun `nothing to fold in leaves the stored counts untouched`() {
        val existing = mapOf("t1" to 7)
        assertEquals(existing, LocalCounters.summed(existing, emptyMap()))
        assertEquals(existing, LocalCounters.summed(emptyMap(), existing))
    }

    // ---- merged -------------------------------------------------

    @Test
    fun `merging timestamps keeps the later like`() {
        // A track has only ever been last liked once, so these take the later
        // rather than adding -- the one map the fold does not sum.
        assertEquals(
            mapOf("t1" to 200L, "t2" to 500L),
            LocalCounters.merged(
                existing = mapOf("t1" to 200L, "t2" to 100L),
                incoming = mapOf("t1" to 150L, "t2" to 500L),
            ),
        )
    }

    @Test
    fun `merging no timestamps in leaves the stored ones untouched`() {
        val existing = mapOf("t1" to 200L)
        assertEquals(existing, LocalCounters.merged(existing, emptyMap()))
    }

    // ---- numbersFrom -------------------------------------------------

    @Test
    fun `channel counts arrive at either integer width`() {
        assertEquals(
            mapOf("t1" to 3L, "t2" to 1_758_499_200_000L),
            LocalCounters.numbersFrom(mapOf("t1" to 3, "t2" to 1_758_499_200_000L)),
        )
    }

    @Test
    fun `entries that are not a count are dropped, not guessed at`() {
        assertEquals(
            mapOf("t1" to 3L),
            LocalCounters.numbersFrom(mapOf("t1" to 3, "t2" to "four", "t3" to null, 7 to 9)),
        )
        assertEquals(emptyMap<String, Long>(), LocalCounters.numbersFrom(null))
    }

    // ---- parseIds / encodeIds -------------------------------------------------

    @Test
    fun `the followed-artist set survives a round trip`() {
        val followed = setOf("artist-1", "artist-2", "ytmusic:UC123")
        assertEquals(followed, LocalCounters.parseIds(LocalCounters.encodeIds(followed)))
    }

    @Test
    fun `no artist followed yet reads as an empty set`() {
        assertEquals(emptySet<String>(), LocalCounters.parseIds(null))
        assertEquals(emptySet<String>(), LocalCounters.parseIds("[]"))
    }

    @Test
    fun `an unreadable followed set degrades to empty instead of throwing`() {
        assertEquals(emptySet<String>(), LocalCounters.parseIds("""["a", """))
        assertEquals(emptySet<String>(), LocalCounters.parseIds("""{"a":1}"""))
    }

    @Test
    fun `adding an artist already in the set is not a second entry`() {
        val followed = LocalCounters.parseIds("""["artist-1"]""") + "artist-1"
        assertEquals(setOf("artist-1"), followed)
        assertTrue("artist-1" in LocalCounters.parseIds(LocalCounters.encodeIds(followed)))
    }

    // ---- shouldFollow -------------------------------------------------

    @Test
    fun `an artist short of the threshold is not followed`() {
        assertFalse(LocalCounters.shouldFollow(4, 5, emptySet(), "artist-1"))
    }

    @Test
    fun `an artist exactly on the threshold is followed`() {
        assertTrue(LocalCounters.shouldFollow(5, 5, emptySet(), "artist-1"))
    }

    @Test
    fun `a count that jumped past the threshold still follows`() {
        // The case `==` could not serve, and the whole of #197: a like counted
        // in the store this one could not see, or the one-time merge landing a
        // count past the threshold, left the artist unfollowed forever.
        assertTrue(LocalCounters.shouldFollow(9, 5, emptySet(), "artist-1"))
    }

    @Test
    fun `an artist already followed is not followed again`() {
        // What keeps `>=` from re-following on every later like.
        assertFalse(LocalCounters.shouldFollow(9, 5, setOf("artist-1"), "artist-1"))
    }

    @Test
    fun `being followed says nothing about the artist beside it`() {
        assertTrue(LocalCounters.shouldFollow(5, 5, setOf("artist-1"), "artist-2"))
    }

    @Test
    fun `the namespaced key a youtube channel is stored under is matched whole`() {
        // YouTube Music ids share the map with Spotify's under a `ytmusic:`
        // prefix, so the bare id must not match the namespaced entry.
        assertFalse(LocalCounters.shouldFollow(5, 5, setOf("ytmusic:UC123"), "ytmusic:UC123"))
        assertTrue(LocalCounters.shouldFollow(5, 5, setOf("ytmusic:UC123"), "UC123"))
    }
}
