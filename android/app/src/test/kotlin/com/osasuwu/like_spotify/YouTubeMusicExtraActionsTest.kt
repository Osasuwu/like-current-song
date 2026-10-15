package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class YouTubeMusicExtraActionsTest {

    // ---- best playlist (#245) -------------------------------------------------

    /**
     * A Data API that knows one playlist, "Best", and what is in it. Writes
     * land in [members], so a second like sees the first one's add.
     */
    private class FakeDataApi(
        val members: MutableSet<String> = mutableSetOf(),
        var refuseAdds: Int = 0,
    ) {
        val calls = mutableListOf<String>()

        fun call(method: String, url: String, body: String?): String {
            val path = url.removePrefix(YouTubeDataApi.API_BASE).substringBefore('?')
            calls += "$method $path"
            return when ("$method $path") {
                "GET /playlists" -> """{"items":[{"id":"PLbest","snippet":{"title":"Best"}}]}"""
                "GET /playlistItems" -> {
                    val videoId = url.substringAfter("videoId=").substringBefore('&')
                    if (videoId in members) {
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
