package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What a YouTube Music like says when Google will not renew its token.
 *
 * The notification that asks for a new sign-in used to fire for a rejected
 * client ID or secret too, and a new sign-in presents the same rejected
 * client — a loop with no end (#204). The message is a pure function so the
 * words are testable without a token, a network or an Android runtime; which
 * refusals still reach the notification is [GoogleTokens.RefreshFailure]'s
 * `needsReauth`, i.e. `YouTubeDataApi.classifyTokenError`, covered in
 * `YouTubeDataApiTest`.
 *
 * The counter's twin is `LikeCounterTest`'s tokenRefusedMessage section: same
 * split, its own credentials.
 */
class YouTubeMusicLikerTokenRefusedTest {

    private fun refused(error: String?, httpCode: Int?, needsReauth: Boolean = false) =
        YouTubeMusicLiker.tokenRefusedMessage(
            GoogleTokens.RefreshFailure("refused", httpCode, needsReauth, error),
        )

    @Test
    fun `a rejected client names the credentials, not a new sign-in`() {
        val message = refused("invalid_client", httpCode = 401)
        assertTrue(message.contains("invalid_client"))
        assertTrue(message.contains("client ID or secret"))
        assertFalse(message.contains("sign-in revoked"))
        assertFalse(message.contains("Sign in"))
    }

    @Test
    fun `an unauthorized client reads the same way`() {
        val message = refused("unauthorized_client", httpCode = 401)
        assertTrue(message.contains("unauthorized_client"))
        assertTrue(message.contains("client ID or secret"))
    }

    @Test
    fun `the credentials are named where they are actually typed`() {
        // The heading on the Connected services screen, from
        // `lib/presentation/screens/connected_services_screen.dart` — the
        // counter's own message points at its own section instead.
        val message = refused("invalid_client", httpCode = 401)
        assertTrue(message.contains("Connected services → YouTube Music setup"))
        assertFalse(message.contains("Shared like counter"))
    }

    @Test
    fun `a revoked sign-in still says the sign-in is gone`() {
        val message = refused("invalid_grant", httpCode = 400, needsReauth = true)
        assertEquals("YouTube Music sign-in revoked", message)
    }

    @Test
    fun `a request that never went out means nobody finished the sign-in`() {
        // No status: `refresh` threw before opening a connection, because the
        // client id or the refresh token is missing.
        assertEquals("YouTube Music sign-in incomplete", refused(null, httpCode = null, needsReauth = true))
    }

    @Test
    fun `anything else is the plain refresh failure`() {
        assertEquals("YouTube token refresh failed", refused("invalid_request", httpCode = 400))
        assertEquals("YouTube token refresh failed", refused(null, httpCode = 503))
    }

    @Test
    fun `no two refusals read the same`() {
        val messages = listOf(
            refused("invalid_client", 401),
            refused("unauthorized_client", 401),
            refused("invalid_grant", 400, needsReauth = true),
            refused(null, null, needsReauth = true),
            refused("invalid_request", 400),
        )
        assertEquals(messages.size, messages.toSet().size)
    }
}
