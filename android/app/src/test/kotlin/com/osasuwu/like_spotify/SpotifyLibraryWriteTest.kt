package com.osasuwu.like_spotify

import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The background like's fallback between `PUT /me/library` and the endpoint it
 * replaced — the decision [SpotifyLikeWorker] delegates to.
 *
 * It is worth pinning down precisely because it is invisible from the phone:
 * both paths end in a liked track, and the only way to tell a needless second
 * round trip (or a swallowed 400) from a healthy write is a test.
 */
class SpotifyLibraryWriteTest {

    @Before
    @After
    fun forgetEndpointChoice() {
        // The decision lives for the process lifetime, so it has to be cleared
        // around every test.
        SpotifyLibraryEndpoints.resetForTesting()
    }

    /** An [HttpURLConnection] that answers [code] without touching a socket. */
    private class FakeConnection(
        private val code: Int,
        private val errorBody: String? = null
    ) : HttpURLConnection(URL("https://api.spotify.com/v1/me/library")) {
        override fun getResponseCode(): Int = code
        override fun getErrorStream(): InputStream? = errorBody?.byteInputStream()
        override fun connect() = Unit
        override fun disconnect() = Unit
        override fun usingProxy(): Boolean = false
    }

    /** Records what the caller was asked to open. */
    private class Calls {
        val genericUrls = mutableListOf<String>()
        var legacyCalls = 0
    }

    private fun saveToLibrary(
        uri: String = SpotifyLibraryEndpoints.trackUri("trk1"),
        calls: Calls,
        generic: () -> HttpURLConnection,
        legacy: () -> HttpURLConnection = {
            throw AssertionError("the legacy endpoint must not be called here")
        }
    ): ApiResult = SpotifyLibraryWrite.saveToLibrary(
        uri,
        generic = { url ->
            calls.genericUrls += url
            generic()
        },
        legacy = {
            calls.legacyCalls++
            legacy()
        }
    )

    // ---- the generic endpoint answers -------------------------------------------------

    @Test
    fun `a 2xx from the generic endpoint is the whole write`() {
        val calls = Calls()

        val result = saveToLibrary(calls = calls, generic = { FakeConnection(200) })

        assertTrue(result.success)
        assertEquals(200, result.statusCode)
        assertNull(result.errorBody)
        assertEquals(0, calls.legacyCalls)
        // The URI travels in the query string, percent-encoded (#150).
        assertEquals(
            listOf("https://api.spotify.com/v1/me/library?uris=spotify%3Atrack%3Atrk1"),
            calls.genericUrls
        )
        // A success on the generic endpoint must never pin the process to the
        // legacy ones.
        assertFalse(SpotifyLibraryEndpoints.useLegacyEndpoints)
    }

    @Test
    fun `any 2xx counts, not only 200`() {
        val calls = Calls()

        val result = saveToLibrary(calls = calls, generic = { FakeConnection(204) })

        assertTrue(result.success)
        assertEquals(204, result.statusCode)
        assertEquals(0, calls.legacyCalls)
    }

    // ---- the fallback -------------------------------------------------

    @Test
    fun `a 403 falls back to the legacy endpoint and remembers the success`() {
        val calls = Calls()

        val result = saveToLibrary(
            calls = calls,
            generic = { FakeConnection(403, """{"error":{"status":403}}""") },
            legacy = { FakeConnection(200) }
        )

        assertTrue(result.success)
        assertEquals(200, result.statusCode)
        assertNull(result.errorBody)
        assertEquals(1, calls.legacyCalls)
        assertTrue(SpotifyLibraryEndpoints.useLegacyEndpoints)
    }

    @Test
    fun `a 404 falls back to the legacy endpoint and remembers the success`() {
        val calls = Calls()

        val result = saveToLibrary(
            calls = calls,
            generic = { FakeConnection(404) },
            legacy = { FakeConnection(200) }
        )

        assertTrue(result.success)
        assertEquals(200, result.statusCode)
        assertEquals(1, calls.legacyCalls)
        assertTrue(SpotifyLibraryEndpoints.useLegacyEndpoints)
    }

    @Test
    fun `once the fallback is remembered the generic endpoint is skipped`() {
        val first = Calls()
        saveToLibrary(
            calls = first,
            generic = { FakeConnection(404) },
            legacy = { FakeConnection(200) }
        )

        val second = Calls()
        val result = saveToLibrary(
            calls = second,
            generic = { throw AssertionError("the generic endpoint must not be retried") },
            legacy = { FakeConnection(200) }
        )

        assertTrue(result.success)
        assertEquals(emptyList<String>(), second.genericUrls)
        assertEquals(1, second.legacyCalls)
    }

    @Test
    fun `a failing legacy call is not remembered`() {
        // A 403 from a missing scope fails on both forms; pinning the process
        // to the legacy endpoints on that would be a permanent downgrade.
        val calls = Calls()

        val result = saveToLibrary(
            calls = calls,
            generic = { FakeConnection(403) },
            legacy = { FakeConnection(403, """{"error":{"status":403,"message":"Insufficient scope"}}""") }
        )

        assertFalse(result.success)
        assertEquals(403, result.statusCode)
        assertEquals("""{"error":{"status":403,"message":"Insufficient scope"}}""", result.errorBody)
        assertFalse(SpotifyLibraryEndpoints.useLegacyEndpoints)
    }

    // ---- the codes that must not fall back -------------------------------------------------

    @Test
    fun `a 400 fails outright instead of falling back`() {
        // 400 means our own payload is wrong (#150, #151): the legacy endpoint
        // cannot fix it, and a second doomed request would only hide the cause.
        val calls = Calls()

        val result = saveToLibrary(
            calls = calls,
            generic = {
                FakeConnection(400, """{"error":{"status":400,"message":"Malformed json"}}""")
            }
        )

        assertFalse(result.success)
        assertEquals(400, result.statusCode)
        assertEquals(0, calls.legacyCalls)
        assertFalse(SpotifyLibraryEndpoints.useLegacyEndpoints)
        // Spotify's own words reach the log, not a bare number.
        assertEquals("""{"error":{"status":400,"message":"Malformed json"}}""", result.errorBody)
    }

    @Test
    fun `a 401 fails outright so the caller can refresh the token`() {
        val calls = Calls()

        val result = saveToLibrary(
            calls = calls,
            generic = { FakeConnection(401, """{"error":{"status":401}}""") }
        )

        assertFalse(result.success)
        assertEquals(401, result.statusCode)
        assertEquals(0, calls.legacyCalls)
    }

    @Test
    fun `a 429 and a 5xx fail outright rather than doubling the traffic`() {
        for (code in listOf(429, 500, 503)) {
            SpotifyLibraryEndpoints.resetForTesting()
            val calls = Calls()

            val result = saveToLibrary(calls = calls, generic = { FakeConnection(code) })

            assertFalse("$code must not fall back", result.success)
            assertEquals(code, result.statusCode)
            assertEquals(0, calls.legacyCalls)
        }
    }

    // ---- the error body -------------------------------------------------

    @Test
    fun `an absent or blank error payload leaves the body null`() {
        val calls = Calls()

        assertNull(saveToLibrary(calls = calls, generic = { FakeConnection(400) }).errorBody)
        assertNull(saveToLibrary(calls = calls, generic = { FakeConnection(400, "   ") }).errorBody)
    }
}
