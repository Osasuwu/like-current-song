package com.osasuwu.like_spotify

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class SpotifyLibraryEndpointsTest {

    @Before
    @After
    fun forgetEndpointChoice() {
        // The decision lives for the process lifetime, so it has to be cleared
        // around every test.
        SpotifyLibraryEndpoints.resetForTesting()
    }

    // ---- shouldTryLegacy -------------------------------------------------

    @Test
    fun `a client without access to the generic endpoint retries the old one`() {
        assertTrue(SpotifyLibraryEndpoints.shouldTryLegacy(404))
        assertTrue(SpotifyLibraryEndpoints.shouldTryLegacy(403))
    }

    @Test
    fun `an expired token is never retried`() {
        // 401 has to surface so the caller refreshes and tries again.
        assertFalse(SpotifyLibraryEndpoints.shouldTryLegacy(401))
    }

    @Test
    fun `a rate limit is never retried`() {
        assertFalse(SpotifyLibraryEndpoints.shouldTryLegacy(429))
    }

    @Test
    fun `a bad request or a server error is never retried`() {
        // 400 is our own payload — a retry cannot fix it; 5xx is transient.
        assertFalse(SpotifyLibraryEndpoints.shouldTryLegacy(400))
        assertFalse(SpotifyLibraryEndpoints.shouldTryLegacy(500))
        assertFalse(SpotifyLibraryEndpoints.shouldTryLegacy(503))
    }

    // ---- URIs -------------------------------------------------

    @Test
    fun `ids become the spotify uris the generic endpoint takes`() {
        assertEquals("spotify:track:trk1", SpotifyLibraryEndpoints.trackUri("trk1"))
        assertEquals("spotify:artist:art1", SpotifyLibraryEndpoints.artistUri("art1"))
    }

    @Test
    fun `the uri travels in the query string, percent-encoded`() {
        // `uris` is a query parameter. Put the list back in a JSON body and
        // Spotify answers 400 every time (#150).
        assertEquals(
            "https://api.spotify.com/v1/me/library?uris=spotify%3Atrack%3Atrk1",
            SpotifyLibraryEndpoints.libraryUrl(SpotifyLibraryEndpoints.trackUri("trk1"))
        )
        assertEquals(
            "https://api.spotify.com/v1/me/library?uris=spotify%3Aartist%3Aart1",
            SpotifyLibraryEndpoints.libraryUrl(SpotifyLibraryEndpoints.artistUri("art1"))
        )
    }

    // ---- the remembered decision -------------------------------------------------

    @Test
    fun `the generic endpoint is used until a legacy call has succeeded`() {
        assertFalse(SpotifyLibraryEndpoints.useLegacyEndpoints)

        SpotifyLibraryEndpoints.rememberLegacyEndpoints()

        assertTrue(SpotifyLibraryEndpoints.useLegacyEndpoints)
    }
}
