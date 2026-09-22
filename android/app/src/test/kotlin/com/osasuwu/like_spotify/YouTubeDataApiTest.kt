package com.osasuwu.like_spotify

import com.osasuwu.like_spotify.YouTubeDataApi.ErrorKind
import com.osasuwu.like_spotify.YouTubeDataApi.Match
import com.osasuwu.like_spotify.YouTubeDataApi.Playlist
import com.osasuwu.like_spotify.YouTubeDataApi.SearchCandidate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class YouTubeDataApiTest {

    // ---- pickMatch -------------------------------------------------

    @Test
    fun `topic art track beats a same-title cover ranked above it`() {
        val candidates = listOf(
            SearchCandidate("cover", "Some Cover Channel", "UC_cover"),
            SearchCandidate("official", "Daft Punk", "UC_official"),
            SearchCandidate("topic", "Daft Punk - Topic", "UC_topic"),
        )
        assertEquals(Match("topic", "UC_topic"), YouTubeDataApi.pickMatch(candidates, "Daft Punk"))
    }

    @Test
    fun `topic match ignores case`() {
        val candidates = listOf(
            SearchCandidate("cover", "Covers", "UC_cover"),
            SearchCandidate("topic", "DAFT PUNK - TOPIC", "UC_topic"),
        )
        assertEquals(Match("topic", "UC_topic"), YouTubeDataApi.pickMatch(candidates, "daft punk"))
    }

    @Test
    fun `falls back to a channel named after the artist`() {
        val candidates = listOf(
            SearchCandidate("cover", "Some Cover Channel", "UC_cover"),
            SearchCandidate("vevo", "DaftPunkVEVO", "UC_vevo"),
            SearchCandidate("official", "Daft Punk Official", "UC_official"),
        )
        assertEquals(Match("official", "UC_official"), YouTubeDataApi.pickMatch(candidates, "Daft Punk"))
    }

    @Test
    fun `falls back to the top hit when no channel matches the artist`() {
        val candidates = listOf(
            SearchCandidate("first", "Channel A", "UC_a"),
            SearchCandidate("second", "Channel B", "UC_b"),
        )
        // Whoever uploaded it, auto-follow must not subscribe the user to them.
        assertEquals(Match("first", null), YouTubeDataApi.pickMatch(candidates, "Daft Punk"))
    }

    @Test
    fun `an artist hit without a channel id is still the video to use`() {
        val candidates = listOf(SearchCandidate("topic", "Daft Punk - Topic"))
        assertEquals(Match("topic", null), YouTubeDataApi.pickMatch(candidates, "Daft Punk"))
    }

    @Test
    fun `blank artist takes the top hit`() {
        val candidates = listOf(
            SearchCandidate("first", " - Topic", "UC_first"),
            SearchCandidate("second", "Anything", "UC_second"),
        )
        assertEquals(Match("first", null), YouTubeDataApi.pickMatch(candidates, ""))
    }

    @Test
    fun `no candidates picks nothing`() {
        assertNull(YouTubeDataApi.pickMatch(emptyList(), "Daft Punk"))
    }

    // ---- parseSearchCandidates -------------------------------------------------

    @Test
    fun `parses search hits and drops ones without a videoId`() {
        val body = """
            {"items": [
              {"id": {"videoId": "a"}, "snippet": {"channelTitle": "X - Topic", "channelId": "UC_x"}},
              {"id": {"channelId": "c"}, "snippet": {"channelTitle": "Y"}},
              {"id": {"videoId": "b"}}
            ]}
        """.trimIndent()
        assertEquals(
            listOf(SearchCandidate("a", "X - Topic", "UC_x"), SearchCandidate("b", "")),
            YouTubeDataApi.parseSearchCandidates(body),
        )
    }

    @Test
    fun `unparseable search body yields no candidates`() {
        assertEquals(emptyList<SearchCandidate>(), YouTubeDataApi.parseSearchCandidates("not json"))
        assertEquals(emptyList<SearchCandidate>(), YouTubeDataApi.parseSearchCandidates("{}"))
    }

    // ---- playlists -------------------------------------------------

    private val playlistsPage = """
        {"items": [
          {"id": "PL_archive", "snippet": {"title": "Archive"}},
          {"id": "", "snippet": {"title": "Nameless"}},
          {"snippet": {"title": "No id at all"}},
          {"id": "PL_best", "snippet": {"title": "Best of 2026"}}
        ], "nextPageToken": "PAGE2"}
    """.trimIndent()

    @Test
    fun `parses playlists and drops entries without an id`() {
        assertEquals(
            listOf(Playlist("PL_archive", "Archive"), Playlist("PL_best", "Best of 2026")),
            YouTubeDataApi.parsePlaylists(playlistsPage),
        )
    }

    @Test
    fun `unparseable playlist body yields no playlists`() {
        assertEquals(emptyList<Playlist>(), YouTubeDataApi.parsePlaylists("not json"))
        assertEquals(emptyList<Playlist>(), YouTubeDataApi.parsePlaylists("{}"))
    }

    @Test
    fun `finds the playlist by name whatever the case and padding`() {
        val playlists = YouTubeDataApi.parsePlaylists(playlistsPage)
        assertEquals("PL_archive", YouTubeDataApi.findPlaylistId(playlists, "  archive "))
        assertEquals("PL_best", YouTubeDataApi.findPlaylistId(playlists, "BEST OF 2026"))
    }

    @Test
    fun `a name nobody has, or no name at all, matches nothing`() {
        val playlists = YouTubeDataApi.parsePlaylists(playlistsPage)
        assertNull(YouTubeDataApi.findPlaylistId(playlists, "Liked Songs"))
        assertNull(YouTubeDataApi.findPlaylistId(playlists, "   "))
    }

    @Test
    fun `the page token runs out on the last page`() {
        assertEquals("PAGE2", YouTubeDataApi.nextPageToken(playlistsPage))
        assertNull(YouTubeDataApi.nextPageToken("""{"items": []}"""))
        assertNull(YouTubeDataApi.nextPageToken("not json"))
    }

    @Test
    fun `a created playlist reports its id`() {
        assertEquals("PL_new", YouTubeDataApi.parseResourceId("""{"kind": "youtube#playlist", "id": "PL_new"}"""))
        assertNull(YouTubeDataApi.parseResourceId("{}"))
    }

    // ---- parsePlaylistItemIds -------------------------------------------------

    @Test
    fun `every copy of the song in the playlist is found`() {
        val body = """
            {"items": [
              {"id": "ITEM1", "contentDetails": {"videoId": "vid"}},
              {"id": "ITEM2", "contentDetails": {"videoId": "other"}},
              {"contentDetails": {"videoId": "vid"}},
              {"id": "ITEM3", "contentDetails": {"videoId": "vid"}}
            ]}
        """.trimIndent()
        assertEquals(listOf("ITEM1", "ITEM3"), YouTubeDataApi.parsePlaylistItemIds(body, "vid"))
    }

    @Test
    fun `a song that is not in the playlist has nothing to remove`() {
        val body = """{"items": [{"id": "ITEM1", "contentDetails": {"videoId": "other"}}]}"""
        assertEquals(emptyList<String>(), YouTubeDataApi.parsePlaylistItemIds(body, "vid"))
        assertEquals(emptyList<String>(), YouTubeDataApi.parsePlaylistItemIds("not json", "vid"))
    }

    // ---- subscriptions -------------------------------------------------

    @Test
    fun `an already-followed channel is a duplicate, not a failure`() {
        assertTrue(YouTubeDataApi.isDuplicateSubscription(YouTubeDataApi.errorReason(googleError("subscriptionDuplicate"))))
        assertFalse(YouTubeDataApi.isDuplicateSubscription(YouTubeDataApi.errorReason(googleError("quotaExceeded"))))
        assertFalse(YouTubeDataApi.isDuplicateSubscription(null))
    }

    // ---- cleanArtist / searchQuery -------------------------------------------------

    @Test
    fun `strips the topic suffix from the artist`() {
        assertEquals("Daft Punk", YouTubeDataApi.cleanArtist("Daft Punk - Topic"))
        assertEquals("Daft Punk", YouTubeDataApi.cleanArtist("  Daft Punk  "))
        assertEquals("", YouTubeDataApi.cleanArtist(null))
    }

    @Test
    fun `search query is artist then title`() {
        assertEquals("Daft Punk One More Time", YouTubeDataApi.searchQuery("Daft Punk", "One More Time"))
        assertEquals("One More Time", YouTubeDataApi.searchQuery("", "One More Time"))
    }

    // ---- classifyApiError -------------------------------------------------

    private fun googleError(reason: String) =
        """{"error": {"code": 403, "errors": [{"reason": "$reason", "domain": "youtube.quota"}]}}"""

    @Test
    fun `quota 403 is rate limited, not a sign-in problem`() {
        assertEquals(ErrorKind.RATE_LIMITED, YouTubeDataApi.classifyApiError(403, googleError("quotaExceeded")))
        assertEquals(ErrorKind.RATE_LIMITED, YouTubeDataApi.classifyApiError(403, googleError("rateLimitExceeded")))
    }

    @Test
    fun `any other 403 needs a new sign-in`() {
        assertEquals(ErrorKind.REAUTH_REQUIRED, YouTubeDataApi.classifyApiError(403, googleError("insufficientPermissions")))
        assertEquals(ErrorKind.REAUTH_REQUIRED, YouTubeDataApi.classifyApiError(403, googleError("forbidden")))
        assertEquals(ErrorKind.REAUTH_REQUIRED, YouTubeDataApi.classifyApiError(403, null))
        assertEquals(ErrorKind.REAUTH_REQUIRED, YouTubeDataApi.classifyApiError(403, "<html>"))
    }

    @Test
    fun `other statuses classify like the desktop provider`() {
        assertEquals(ErrorKind.TOKEN_EXPIRED, YouTubeDataApi.classifyApiError(401, null))
        assertEquals(ErrorKind.RATE_LIMITED, YouTubeDataApi.classifyApiError(429, null))
        assertEquals(ErrorKind.TRANSIENT, YouTubeDataApi.classifyApiError(503, null))
        assertEquals(ErrorKind.FAILED, YouTubeDataApi.classifyApiError(404, null))
        assertEquals(ErrorKind.FAILED, YouTubeDataApi.classifyApiError(400, googleError("quotaExceeded")))
    }

    // ---- classifyTokenError -------------------------------------------------

    @Test
    fun `revoked refresh token needs a new sign-in`() {
        assertEquals(ErrorKind.REAUTH_REQUIRED, YouTubeDataApi.classifyTokenError(400, """{"error": "invalid_grant"}"""))
    }

    /**
     * The half of #204 the Dart side has to match: `GoogleDeviceFlow.refresh`
     * in `lib/data/google/google_device_flow.dart` raises
     * `GoogleSignInRevoked` for `invalid_grant` and for nothing else, pinned
     * by "a rejected client keeps the stored sign-in" in
     * `test/data/ytmusic/ytmusic_music_service_repository_test.dart`. Both
     * halves refresh the same stored tokens, so the two rules have to be the
     * same rule.
     */
    @Test
    fun `a rejected client is not a re-auth, the way the Dart half has it`() {
        assertEquals(ErrorKind.FAILED, YouTubeDataApi.classifyTokenError(401, """{"error": "invalid_client"}"""))
        assertEquals(ErrorKind.FAILED, YouTubeDataApi.classifyTokenError(400, """{"error": "unauthorized_client"}"""))
        assertTrue(YouTubeDataApi.isRejectedClient("invalid_client"))
        assertTrue(YouTubeDataApi.isRejectedClient("unauthorized_client"))
        assertFalse(YouTubeDataApi.isRejectedClient("invalid_grant"))
        assertFalse(YouTubeDataApi.isRejectedClient(null))
    }

    @Test
    fun `token endpoint outage is transient`() {
        assertEquals(ErrorKind.TRANSIENT, YouTubeDataApi.classifyTokenError(503, null))
        assertEquals(ErrorKind.FAILED, YouTubeDataApi.classifyTokenError(400, """{"error": "invalid_request"}"""))
    }

    // ---- cooldown key -------------------------------------------------

    @Test
    fun `cooldown key is case-insensitive title plus artist`() {
        assertEquals(
            YouTubeMusicLiker.cooldownKey("One More Time", "Daft Punk"),
            YouTubeMusicLiker.cooldownKey(" one more time ", "DAFT PUNK"),
        )
        assertNotEquals(
            YouTubeMusicLiker.cooldownKey("One More Time", "Daft Punk"),
            YouTubeMusicLiker.cooldownKey("One More Time", "A Cover Band"),
        )
    }
}
