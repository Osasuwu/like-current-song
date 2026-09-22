package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GoogleTokensTest {

    private val now = 1_700_000_000_000L

    // ---- needsRefresh -------------------------------------------------

    @Test
    fun `a token with hours left is handed out as it is`() {
        assertFalse(
            GoogleTokens.needsRefresh(
                expiresAtMs = now + 2 * 60 * 60_000L,
                nowMs = now,
                hasAccessToken = true,
            ),
        )
    }

    @Test
    fun `a token inside the margin is refreshed before it dies`() {
        assertTrue(
            GoogleTokens.needsRefresh(
                expiresAtMs = now + GoogleTokens.REFRESH_MARGIN_MS - 1,
                nowMs = now,
                hasAccessToken = true,
            ),
        )
    }

    @Test
    fun `an expired token is refreshed`() {
        assertTrue(
            GoogleTokens.needsRefresh(expiresAtMs = now - 60_000L, nowMs = now, hasAccessToken = true),
        )
    }

    @Test
    fun `a missing expiry means unknown, so refresh`() {
        // The whole of the bug: `expiresAt > 0L && …` read a missing expiry as
        // "never stale", so a stored access token was handed out for ever and
        // every like fell back to the local tally once it had quietly died.
        assertTrue(GoogleTokens.needsRefresh(expiresAtMs = 0L, nowMs = now, hasAccessToken = true))
        assertTrue(GoogleTokens.needsRefresh(expiresAtMs = -1L, nowMs = now, hasAccessToken = true))
    }

    @Test
    fun `no stored token is always a refresh`() {
        assertTrue(
            GoogleTokens.needsRefresh(
                expiresAtMs = now + 2 * 60 * 60_000L,
                nowMs = now,
                hasAccessToken = false,
            ),
        )
    }

    @Test
    fun `forcing a refresh beats a token with hours left`() {
        assertTrue(
            GoogleTokens.needsRefresh(
                expiresAtMs = now + 2 * 60 * 60_000L,
                nowMs = now,
                hasAccessToken = true,
                forceRefresh = true,
            ),
        )
    }

    @Test
    fun `the assumed expiry keeps a silent refresh answer down to one an hour`() {
        // What `refresh` stores when Google leaves `expires_in` out. It has to
        // land outside the margin, or "no expiry means refresh" would mean a
        // token exchange on every single like.
        val stored = now + GoogleTokens.DEFAULT_EXPIRES_IN_SEC * 1000L
        assertFalse(GoogleTokens.needsRefresh(expiresAtMs = stored, nowMs = now, hasAccessToken = true))
    }

    // ---- oauthError -------------------------------------------------

    @Test
    fun `reads google's own error code out of a refusal`() {
        assertEquals(
            "invalid_client",
            GoogleTokens.oauthError(
                """{"error":"invalid_client","error_description":"The OAuth client was not found."}""",
            ),
        )
        assertEquals("invalid_grant", GoogleTokens.oauthError("""{"error":"invalid_grant"}"""))
    }

    @Test
    fun `a body with no code to read is no code`() {
        assertNull(GoogleTokens.oauthError(null))
        assertNull(GoogleTokens.oauthError(""))
        assertNull(GoogleTokens.oauthError("<html>502 Bad Gateway</html>"))
        assertNull(GoogleTokens.oauthError("""{"error":""}"""))
        assertNull(GoogleTokens.oauthError("""{"message":"nope"}"""))
    }
}
