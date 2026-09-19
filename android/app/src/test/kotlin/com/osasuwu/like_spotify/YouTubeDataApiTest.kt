package com.osasuwu.like_spotify

import com.osasuwu.like_spotify.YouTubeDataApi.ErrorKind
import com.osasuwu.like_spotify.YouTubeDataApi.SearchCandidate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class YouTubeDataApiTest {

    // ---- pickVideo -------------------------------------------------

    @Test
    fun `topic art track beats a same-title cover ranked above it`() {
        val candidates = listOf(
            SearchCandidate("cover", "Some Cover Channel"),
            SearchCandidate("official", "Daft Punk"),
            SearchCandidate("topic", "Daft Punk - Topic"),
        )
        assertEquals("topic", YouTubeDataApi.pickVideo(candidates, "Daft Punk"))
    }

    @Test
    fun `topic match ignores case`() {
        val candidates = listOf(
            SearchCandidate("cover", "Covers"),
            SearchCandidate("topic", "DAFT PUNK - TOPIC"),
        )
        assertEquals("topic", YouTubeDataApi.pickVideo(candidates, "daft punk"))
    }

    @Test
    fun `falls back to a channel named after the artist`() {
        val candidates = listOf(
            SearchCandidate("cover", "Some Cover Channel"),
            SearchCandidate("vevo", "DaftPunkVEVO"),
            SearchCandidate("official", "Daft Punk Official"),
        )
        assertEquals("official", YouTubeDataApi.pickVideo(candidates, "Daft Punk"))
    }

    @Test
    fun `falls back to the top hit when no channel matches the artist`() {
        val candidates = listOf(
            SearchCandidate("first", "Channel A"),
            SearchCandidate("second", "Channel B"),
        )
        assertEquals("first", YouTubeDataApi.pickVideo(candidates, "Daft Punk"))
    }

    @Test
    fun `blank artist takes the top hit`() {
        val candidates = listOf(
            SearchCandidate("first", " - Topic"),
            SearchCandidate("second", "Anything"),
        )
        assertEquals("first", YouTubeDataApi.pickVideo(candidates, ""))
    }

    @Test
    fun `no candidates picks nothing`() {
        assertNull(YouTubeDataApi.pickVideo(emptyList(), "Daft Punk"))
    }

    // ---- parseSearchCandidates -------------------------------------------------

    @Test
    fun `parses search hits and drops ones without a videoId`() {
        val body = """
            {"items": [
              {"id": {"videoId": "a"}, "snippet": {"channelTitle": "X - Topic"}},
              {"id": {"channelId": "c"}, "snippet": {"channelTitle": "Y"}},
              {"id": {"videoId": "b"}}
            ]}
        """.trimIndent()
        assertEquals(
            listOf(SearchCandidate("a", "X - Topic"), SearchCandidate("b", "")),
            YouTubeDataApi.parseSearchCandidates(body),
        )
    }

    @Test
    fun `unparseable search body yields no candidates`() {
        assertEquals(emptyList<SearchCandidate>(), YouTubeDataApi.parseSearchCandidates("not json"))
        assertEquals(emptyList<SearchCandidate>(), YouTubeDataApi.parseSearchCandidates("{}"))
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
        assertEquals(ErrorKind.REAUTH_REQUIRED, YouTubeDataApi.classifyTokenError(401, """{"error": "invalid_client"}"""))
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
