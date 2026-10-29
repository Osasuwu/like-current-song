package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The follow-artist steps of a background Spotify like and the undo leg each
 * hands the journal (#273, #282): the local tally, the shared sheet's tally
 * row, and the follow. The worker's artist loop is these calls plus the
 * journal and the Spotify calls it hands them.
 */
class ArtistFollowingTest {

    private val legs = mutableListOf<UndoLeg>()

    // ---- trackCount: this device's tally ----

    @Test
    fun `a track new to the artist's tally hands the undo one artist-track leg`() {
        val prefs = FakeSharedPreferences()

        val count = ArtistFollowing.trackCount(prefs, "artist-a", "t1", { legs += it }) { null }

        assertEquals(1, count)
        assertEquals(listOf<UndoLeg>(UndoLeg.ArtistTrack("artist-a")), legs)
    }

    @Test
    fun `a track the tally already held hands the undo nothing`() {
        val prefs = FakeSharedPreferences()
        LocalCounters.recordArtistTrack(prefs, "artist-a", "t1")

        ArtistFollowing.trackCount(prefs, "artist-a", "t1", { legs += it }) { null }

        assertEquals(emptyList<UndoLeg>(), legs)
    }

    @Test
    fun `the shared count decides when it answers, and the local leg is still handed over`() {
        val prefs = FakeSharedPreferences()

        val count = ArtistFollowing.trackCount(prefs, "artist-a", "t1", { legs += it }) { 7 }

        assertEquals(7, count)
        assertEquals(listOf<UndoLeg>(UndoLeg.ArtistTrack("artist-a")), legs)
    }

    // ---- sheetTrackCount: the shared sheet's tally row ----

    private val target = LikeCounter.Target("sheet-1", "me")

    private val artistTab = """
        {"values":[
          ["user_id","artist_id","track_id","created_at"],
          ["me","artist-a","t1","2026-01-01T00:00:00Z"]
        ]}
    """.trimIndent()

    private fun sheet(appendStatus: Int) = FakeSheet { method, _ ->
        if (method == "GET") FakeSheet.Reply(200, artistTab) else FakeSheet.Reply(appendStatus, "{}")
    }

    @Test
    fun `a row this like appended to the sheet's tally hands the undo one tally-row leg for that sheet`() {
        val sheet = sheet(appendStatus = 200)

        val outcome = ArtistFollowing.sheetTrackCount(
            FakeSheet.signedInPrefs(), target, "artist-a", "t2", { legs += it }, sheet::open,
        )

        assertEquals(2, outcome.count)
        assertEquals(listOf("GET", "POST"), sheet.requests.map { it.method })
        assertEquals(listOf<UndoLeg>(UndoLeg.ArtistTrackRow("artist-a", target)), legs)
    }

    @Test
    fun `a triple the sheet already held is not appended and hands the undo nothing`() {
        val sheet = sheet(appendStatus = 200)

        val outcome = ArtistFollowing.sheetTrackCount(
            FakeSheet.signedInPrefs(), target, "artist-a", "t1", { legs += it }, sheet::open,
        )

        assertEquals(1, outcome.count)
        assertEquals(listOf("GET"), sheet.requests.map { it.method })
        assertEquals(emptyList<UndoLeg>(), legs)
    }

    @Test
    fun `an append the sheet refused hands the undo nothing`() {
        val sheet = sheet(appendStatus = 500)

        val outcome = ArtistFollowing.sheetTrackCount(
            FakeSheet.signedInPrefs(), target, "artist-a", "t2", { legs += it }, sheet::open,
        )

        assertEquals(500, outcome.httpCode)
        assertEquals(emptyList<UndoLeg>(), legs)
    }

    // ---- follow ----

    private fun follow(prefs: FakeSharedPreferences, wasFollowing: Boolean?, success: Boolean = true): ApiResult =
        ArtistFollowing.follow(prefs, "artist-a", wasFollowing, { legs += it }) {
            ApiResult(success = success, statusCode = if (success) 204 else 403, errorBody = null)
        }

    @Test
    fun `a follow of an artist the user did not follow hands the undo a leg that unfollows`() {
        val prefs = FakeSharedPreferences()

        assertTrue(follow(prefs, wasFollowing = false).success)

        assertEquals(listOf<UndoLeg>(UndoLeg.ArtistFollow("artist-a", alreadyFollowed = false)), legs)
        assertEquals(setOf("artist-a"), LocalCounters.followedArtists(prefs))
    }

    @Test
    fun `a follow of an artist already followed, or with no answer, hands the undo a leg that keeps the follow`() {
        follow(FakeSharedPreferences(), wasFollowing = true)
        follow(FakeSharedPreferences(), wasFollowing = null)

        assertEquals(
            listOf<UndoLeg>(
                UndoLeg.ArtistFollow("artist-a", alreadyFollowed = true),
                UndoLeg.ArtistFollow("artist-a", alreadyFollowed = true),
            ),
            legs,
        )
    }

    @Test
    fun `a follow Spotify refused hands the undo nothing and is not remembered`() {
        val prefs = FakeSharedPreferences()

        assertFalse(follow(prefs, wasFollowing = false, success = false).success)

        assertEquals(emptyList<UndoLeg>(), legs)
        assertEquals(emptySet<String>(), LocalCounters.followedArtists(prefs))
    }
}
