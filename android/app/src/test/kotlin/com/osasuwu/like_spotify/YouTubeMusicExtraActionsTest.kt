package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class YouTubeMusicExtraActionsTest {

    // ---- best playlist (#245) -------------------------------------------------

    /**
     * A Data API that knows two playlists, "Best" and "Archive", and what is
     * in them. Writes land in [members] and [archived], so a second like sees
     * the first one's add.
     */
    private class FakeDataApi(
        val members: MutableSet<String> = mutableSetOf(),
        var refuseAdds: Int = 0,
        /** The archive's videos, one entry per copy: YouTube allows duplicates. */
        archive: List<String> = emptyList(),
        /** How many deletes go through before the rest are refused; null is all. */
        val deletesAllowed: Int? = null,
        /** What `subscriptions.insert` throws; null subscribes. */
        var subscribeRefusal: ApiFailure? = null,
    ) {
        val calls = mutableListOf<String>()
        private val archiveItems = archive.withIndex().associate { (i, v) -> "arch-$i" to v }.toMutableMap()
        private var deletes = 0

        fun archived(): List<String> = archiveItems.values.toList()

        fun call(method: String, url: String, body: String?): String {
            val path = url.removePrefix(YouTubeDataApi.API_BASE).substringBefore('?')
            calls += "$method $path"
            return when ("$method $path") {
                "GET /playlists" ->
                    """{"items":[{"id":"PLbest","snippet":{"title":"Best"}},""" +
                        """{"id":"PLarchive","snippet":{"title":"Archive"}}]}"""
                "GET /playlistItems" -> {
                    val videoId = url.substringAfter("videoId=").substringBefore('&')
                    if (url.contains("playlistId=PLarchive")) {
                        val items = archiveItems.filterValues { it == videoId }.keys.joinToString(",") {
                            """{"id":"$it","contentDetails":{"videoId":"$videoId"}}"""
                        }
                        """{"items":[$items]}"""
                    } else if (videoId in members) {
                        """{"items":[{"id":"item-1","contentDetails":{"videoId":"$videoId"}}]}"""
                    } else {
                        """{"items":[]}"""
                    }
                }
                "POST /playlistItems" -> {
                    if (refuseAdds > 0) {
                        refuseAdds--
                        throw ApiFailure("HTTP 503", 503)
                    }
                    members += Regex("\"videoId\":\"([^\"]+)\"").find(body.orEmpty())!!.groupValues[1]
                    "{}"
                }
                "DELETE /playlistItems" -> {
                    if (deletesAllowed != null && deletes >= deletesAllowed) throw ApiFailure("HTTP 500", 500)
                    deletes++
                    archiveItems.remove(url.substringAfter("id="))
                    ""
                }
                "POST /subscriptions" -> subscribeRefusal?.let { throw it } ?: "{}"
                else -> error("unexpected call: $method $url")
            }
        }

        fun count(call: String) = calls.count { it == call }
    }

    private fun bestRuleOn(threshold: Int = 3) = FakeSharedPreferences().apply {
        values[AppConstants.KEY_RULE_BEST_ENABLED] = true
        values[AppConstants.KEY_RULE_BEST_PLAYLIST_NAME] = "Best"
        values[AppConstants.KEY_RULE_BEST_THRESHOLD] = threshold
    }

    private fun like(prefs: FakeSharedPreferences, api: FakeDataApi, count: Int) =
        YouTubeMusicExtraActions(prefs, api::call, { _, _, _, _ -> })
            .run(YouTubeDataApi.Match("vid", null), sharedLikeCount = count)

    @Test
    fun `a song short of the threshold is left alone`() {
        val api = FakeDataApi()
        like(bestRuleOn(), api, count = 2)
        assertEquals(emptyList<String>(), api.calls)
    }

    @Test
    fun `the like that reaches the threshold promotes the song`() {
        val api = FakeDataApi()
        like(bestRuleOn(), api, count = 3)
        assertEquals(1, api.count("POST /playlistItems"))
        assertEquals(setOf("vid"), api.members)
    }

    @Test
    fun `a count that landed past the threshold still promotes the song`() {
        // The case `==` could not serve: the threshold lowered below the
        // count, or likes counted on another device through the shared sheet.
        val api = FakeDataApi()
        like(bestRuleOn(), api, count = 7)
        assertEquals(1, api.count("POST /playlistItems"))
    }

    @Test
    fun `later likes do not add the song again`() {
        val prefs = bestRuleOn()
        val api = FakeDataApi()
        listOf(3, 4, 5, 99).forEach { like(prefs, api, it) }
        assertEquals(1, api.count("POST /playlistItems"))
        // The memory answers after the first time: no second membership read.
        assertEquals(1, api.count("GET /playlistItems"))
    }

    @Test
    fun `a song already in the playlist is remembered, not added a second time`() {
        // Promoted by another device, or before the memory existed: YouTube
        // accepts the duplicate, so only the membership check prevents it.
        val prefs = bestRuleOn()
        val api = FakeDataApi(members = mutableSetOf("vid"))
        like(prefs, api, count = 5)
        // Taken out by hand afterwards: a later like respects that.
        api.members.clear()
        like(prefs, api, count = 6)
        assertEquals(0, api.count("POST /playlistItems"))
        assertEquals(1, api.count("GET /playlistItems"))
    }

    @Test
    fun `an add the API refused is retried on the next like`() {
        val prefs = bestRuleOn()
        val api = FakeDataApi(refuseAdds = 1)
        like(prefs, api, count = 3)
        assertEquals(emptySet<String>(), api.members)
        like(prefs, api, count = 4)
        assertEquals(setOf("vid"), api.members)
    }

    // ---- follow artist (#243) -------------------------------------------------

    private fun followRuleOn(threshold: Int = 3) = FakeSharedPreferences().apply {
        values[AppConstants.KEY_RULE_FOLLOW_ARTIST_ENABLED] = true
        values[AppConstants.KEY_RULE_FOLLOW_ARTIST_THRESHOLD] = threshold
    }

    private fun likeVideo(
        prefs: FakeSharedPreferences,
        api: FakeDataApi,
        videoId: String,
        sharedArtistTrackCount: (String, String) -> Int? = { _, _ -> null },
    ) = YouTubeMusicExtraActions(prefs, api::call, { _, _, _, _ -> }, sharedArtistTrackCount)
        .run(YouTubeDataApi.Match(videoId, "UCartist"), sharedLikeCount = null)

    @Test
    fun `without a sheet one video liked again and again never follows its artist`() {
        val prefs = followRuleOn(threshold = 3)
        val api = FakeDataApi()
        repeat(6) { likeVideo(prefs, api, "vid-a") }
        assertEquals(0, api.count("POST /subscriptions"))
    }

    @Test
    fun `without a sheet the third distinct video of an artist follows them, once`() {
        val prefs = followRuleOn(threshold = 3)
        val api = FakeDataApi()
        likeVideo(prefs, api, "vid-a")
        likeVideo(prefs, api, "vid-b")
        likeVideo(prefs, api, "vid-a")
        assertEquals(0, api.count("POST /subscriptions"))
        likeVideo(prefs, api, "vid-c")
        assertEquals(1, api.count("POST /subscriptions"))
        likeVideo(prefs, api, "vid-d")
        assertEquals(1, api.count("POST /subscriptions"))
        assertEquals(setOf("ytmusic:UCartist"), LocalCounters.followedArtists(prefs))
    }

    @Test
    fun `with a sheet its distinct-track count decides, asked by bare channel and video`() {
        val prefs = followRuleOn(threshold = 3)
        val api = FakeDataApi()
        val asked = mutableListOf<String>()
        likeVideo(prefs, api, "vid-a") { channel, video -> asked += "$channel/$video"; 3 }
        assertEquals(listOf("UCartist/vid-a"), asked)
        assertEquals(1, api.count("POST /subscriptions"))
    }

    // ---- what the undo gets (#274) -------------------------------------------------

    private fun archiveRuleOn() = FakeSharedPreferences().apply {
        values[AppConstants.KEY_RULE_ARCHIVE_REMOVE_ENABLED] = true
        values[AppConstants.KEY_RULE_ARCHIVE_PLAYLIST_NAME] = "Archive"
    }

    /** The legs one like hands the undo journal. */
    private fun journaled(
        prefs: FakeSharedPreferences,
        api: FakeDataApi,
        videoId: String = "vid",
        sharedLikeCount: Int? = null,
    ): List<UndoLeg> {
        val legs = mutableListOf<UndoLeg>()
        YouTubeMusicExtraActions(prefs, api::call, { _, _, _, _ -> }) { legs += it }
            .run(YouTubeDataApi.Match(videoId, "UCartist"), sharedLikeCount)
        return legs
    }

    @Test
    fun `an archive removal hands the undo the playlist and every copy it took out`() {
        val api = FakeDataApi(archive = listOf("vid", "other", "vid"))

        val legs = journaled(archiveRuleOn(), api)

        assertEquals(listOf("other"), api.archived())
        assertEquals(listOf<UndoLeg>(UndoLeg.ArchiveRemove("PLarchive", 2)), legs)
    }

    @Test
    fun `an archive removal cut short hands the undo only the copies it took out`() {
        val api = FakeDataApi(archive = listOf("vid", "vid", "vid"), deletesAllowed = 1)

        val legs = journaled(archiveRuleOn(), api)

        assertEquals(listOf("vid", "vid"), api.archived())
        assertEquals(listOf<UndoLeg>(UndoLeg.ArchiveRemove("PLarchive", 1)), legs)
    }

    @Test
    fun `a promotion counted on this device hands the undo the local count and the best playlist`() {
        val legs = journaled(bestRuleOn(threshold = 1), FakeDataApi())

        assertEquals(listOf(UndoLeg.TrackCount(null), UndoLeg.BestPromote("PLbest")), legs)
    }

    @Test
    fun `a promotion counted on the sheet hands the undo no local count`() {
        val legs = journaled(bestRuleOn(threshold = 3), FakeDataApi(), sharedLikeCount = 3)

        assertEquals(listOf<UndoLeg>(UndoLeg.BestPromote("PLbest")), legs)
    }

    @Test
    fun `a like that promoted nothing hands the undo no best leg`() {
        // Short of the threshold, and over it but already there: neither added it.
        assertEquals(emptyList<UndoLeg>(), journaled(bestRuleOn(threshold = 3), FakeDataApi(), sharedLikeCount = 2))
        val already = FakeDataApi(members = mutableSetOf("vid"))
        assertEquals(emptyList<UndoLeg>(), journaled(bestRuleOn(threshold = 3), already, sharedLikeCount = 5))
    }

    @Test
    fun `an artist's new video hands the undo its tally entry, a repeat does not`() {
        val prefs = followRuleOn(threshold = 3)
        val api = FakeDataApi()

        assertEquals(listOf<UndoLeg>(UndoLeg.ArtistTrack("UCartist")), journaled(prefs, api, "vid-a"))
        assertEquals(emptyList<UndoLeg>(), journaled(prefs, api, "vid-a"))
    }

    @Test
    fun `a subscription this like made hands the undo the follow to take back`() {
        val legs = journaled(followRuleOn(threshold = 1), FakeDataApi(), "vid-a")

        assertEquals(
            listOf(UndoLeg.ArtistTrack("UCartist"), UndoLeg.ArtistFollow("UCartist", alreadyFollowed = false)),
            legs,
        )
    }

    @Test
    fun `a channel the user had already subscribed to is handed over as already followed`() {
        val api = FakeDataApi(subscribeRefusal = ApiFailure("already subscribed", 400, "subscriptionDuplicate"))

        val legs = journaled(followRuleOn(threshold = 1), api, "vid-a")

        assertEquals(
            listOf(UndoLeg.ArtistTrack("UCartist"), UndoLeg.ArtistFollow("UCartist", alreadyFollowed = true)),
            legs,
        )
    }

    @Test
    fun `a refused subscription hands the undo no follow`() {
        val api = FakeDataApi(subscribeRefusal = ApiFailure("HTTP 403", 403, "forbidden"))

        val legs = journaled(followRuleOn(threshold = 1), api, "vid-a")

        assertEquals(listOf<UndoLeg>(UndoLeg.ArtistTrack("UCartist")), legs)
    }

    @Test
    fun `an add names the playlist it went to, for the undo of the like's playlist leg`() {
        val actions = YouTubeMusicExtraActions(FakeSharedPreferences(), FakeDataApi()::call, { _, _, _, _ -> })

        assertEquals("PLbest", actions.addToPlaylist("Best", "vid", "like_playlist_add", what = null))
    }

    // ---- countKey -------------------------------------------------

    @Test
    fun `youtube ids are namespaced apart from spotify ids`() {
        // Both pipelines write the same local count maps.
        val id = "dQw4w9WgXcQ"
        assertEquals("ytmusic:$id", YouTubeMusicExtraActions.countKey(id))
        assertNotEquals(id, YouTubeMusicExtraActions.countKey(id))
    }

    @Test
    fun `different ids keep different counts`() {
        assertNotEquals(
            YouTubeMusicExtraActions.countKey("UC_artist_a"),
            YouTubeMusicExtraActions.countKey("UC_artist_b"),
        )
    }
}
