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

    // ---- shouldPromote (#245) -------------------------------------------------

    @Test
    fun `a track short of the threshold is not promoted`() {
        assertFalse(LocalCounters.shouldPromote(2, 3, emptySet(), "trk-a"))
    }

    @Test
    fun `a track exactly on the threshold is promoted`() {
        assertTrue(LocalCounters.shouldPromote(3, 3, emptySet(), "trk-a"))
    }

    @Test
    fun `a count that landed past the threshold still promotes`() {
        // The case `==` could not serve: a lowered threshold, or likes
        // counted on another device through the shared sheet.
        assertTrue(LocalCounters.shouldPromote(8, 3, emptySet(), "trk-a"))
    }

    @Test
    fun `a track already promoted is not promoted again`() {
        assertFalse(LocalCounters.shouldPromote(8, 3, setOf("trk-a"), "trk-a"))
    }

    @Test
    fun `being promoted says nothing about the track beside it`() {
        assertTrue(LocalCounters.shouldPromote(3, 3, setOf("trk-a"), "trk-b"))
    }

    @Test
    fun `a promoted track survives a round trip through storage`() {
        val prefs = FakeSharedPreferences()
        LocalCounters.markTrackPromoted(prefs, "trk-a")
        LocalCounters.markTrackPromoted(prefs, "ytmusic:vid")
        assertEquals(setOf("trk-a", "ytmusic:vid"), LocalCounters.promotedTracks(prefs))
        assertEquals(emptySet<String>(), LocalCounters.followedArtists(prefs))
    }

    // ---- recordArtistTrack (#243) -------------------------------------------------

    @Test
    fun `liking one track again is still one distinct track for its artist`() {
        val prefs = FakeSharedPreferences()
        assertEquals(1, LocalCounters.recordArtistTrack(prefs, "artist-1", "trk-a"))
        assertEquals(1, LocalCounters.recordArtistTrack(prefs, "artist-1", "trk-a"))
        assertEquals(1, LocalCounters.recordArtistTrack(prefs, "artist-1", "trk-a"))
    }

    @Test
    fun `each distinct track counts once, per artist`() {
        val prefs = FakeSharedPreferences()
        LocalCounters.recordArtistTrack(prefs, "artist-1", "trk-a")
        assertEquals(2, LocalCounters.recordArtistTrack(prefs, "artist-1", "trk-b"))
        assertEquals(1, LocalCounters.recordArtistTrack(prefs, "artist-2", "trk-a"))
        assertEquals(3, LocalCounters.recordArtistTrack(prefs, "artist-1", "trk-c"))
    }

    @Test
    fun `old like counts give an upgraded install no distinct tracks`() {
        // AC4: the like tally a past version counted is not a track count, so
        // it seeds nothing -- the set starts empty whatever the tally says.
        val prefs = FakeSharedPreferences()
        prefs.values[AppConstants.KEY_ARTIST_LIKE_COUNTS] = """{"artist-1":40}"""
        assertEquals(1, LocalCounters.recordArtistTrack(prefs, "artist-1", "trk-a"))
    }

    @Test
    fun `unreadable stored artist tracks degrade to empty instead of throwing`() {
        val prefs = FakeSharedPreferences()
        prefs.values[AppConstants.KEY_ARTIST_LIKED_TRACKS] = """{"artist-1":["trk-a", """
        assertEquals(1, LocalCounters.recordArtistTrack(prefs, "artist-1", "trk-b"))
    }

    // ---- artistFollowCount (#243) -------------------------------------------------

    @Test
    fun `without a sheet the follow count is the distinct-track count`() {
        val prefs = FakeSharedPreferences()
        repeat(4) { LocalCounters.artistFollowCount(prefs, "artist-1", "trk-a") { null } }
        assertEquals(1, LocalCounters.artistFollowCount(prefs, "artist-1", "trk-a") { null })
        assertEquals(2, LocalCounters.artistFollowCount(prefs, "artist-1", "trk-b") { null })
    }

    @Test
    fun `the sheet's answer is the follow count when there is one`() {
        val prefs = FakeSharedPreferences()
        assertEquals(7, LocalCounters.artistFollowCount(prefs, "artist-1", "trk-a") { 7 })
    }

    @Test
    fun `a track the sheet counted is still recorded on this device`() {
        // So losing the sheet later falls back on a set that is short, never
        // inflated.
        val prefs = FakeSharedPreferences()
        LocalCounters.artistFollowCount(prefs, "artist-1", "trk-a") { 7 }
        assertEquals(2, LocalCounters.artistFollowCount(prefs, "artist-1", "trk-b") { null })
    }

    @Test
    fun `only a track new to the artist is reported as added`() {
        // The undo journal (#273) records the leg from this, so a track the
        // artist already had is never taken away by an undo.
        val prefs = FakeSharedPreferences()
        val added = mutableListOf<String>()
        LocalCounters.artistFollowCount(prefs, "artist-1", "trk-a", onAdded = { added += "trk-a" }) { null }
        LocalCounters.artistFollowCount(prefs, "artist-1", "trk-a", onAdded = { added += "trk-a again" }) { null }
        LocalCounters.artistFollowCount(prefs, "artist-1", "trk-b", onAdded = { added += "trk-b" }) { 7 }
        assertEquals(listOf("trk-a", "trk-b"), added)
    }

    // ---- undo of the artist legs (#273) -------------------------------------------------

    @Test
    fun `an undone track leaves the artist's other tracks and other artists alone`() {
        val prefs = FakeSharedPreferences()
        LocalCounters.recordArtistTrack(prefs, "artist-1", "trk-a")
        LocalCounters.recordArtistTrack(prefs, "artist-2", "trk-b")
        LocalCounters.recordArtistTrack(prefs, "artist-1", "trk-b")

        LocalCounters.forgetArtistTrack(prefs, "artist-1", "trk-b")

        assertEquals(
            mapOf("artist-1" to setOf("trk-a"), "artist-2" to setOf("trk-b")),
            LocalCounters.parseArtistTracks(prefs.getString(AppConstants.KEY_ARTIST_LIKED_TRACKS, null)),
        )
    }

    @Test
    fun `an undone follow forgets only that artist`() {
        val prefs = FakeSharedPreferences()
        LocalCounters.markArtistFollowed(prefs, "artist-1")
        LocalCounters.markArtistFollowed(prefs, "artist-2")

        LocalCounters.forgetFollowed(prefs, "artist-1")

        assertEquals(setOf("artist-2"), LocalCounters.followedArtists(prefs))
    }

    // ---- restoreLikedAt (#267) -------------------------------------------------

    @Test
    fun `an undone first like leaves the track never liked`() {
        // The cooldown reads this stamp, so a stamp left behind would skip
        // the next like of the track the user just undid.
        val prefs = FakeSharedPreferences()
        LocalCounters.recordLikedAt(prefs, "trk-b", 500L)
        LocalCounters.recordLikedAt(prefs, "trk-a", 1_000L)
        LocalCounters.restoreLikedAt(prefs, "trk-a", null)
        assertNull(LocalCounters.lastLikedAt(prefs, "trk-a"))
        assertEquals(500L, LocalCounters.lastLikedAt(prefs, "trk-b"))
    }

    @Test
    fun `an undone repeat like puts back the like before it`() {
        val prefs = FakeSharedPreferences()
        LocalCounters.recordLikedAt(prefs, "trk-a", 1_000L)
        LocalCounters.recordLikedAt(prefs, "trk-a", 9_000L)
        LocalCounters.restoreLikedAt(prefs, "trk-a", 1_000L)
        assertEquals(1_000L, LocalCounters.lastLikedAt(prefs, "trk-a"))
    }
}
