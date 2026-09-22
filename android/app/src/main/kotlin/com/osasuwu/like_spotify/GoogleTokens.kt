package com.osasuwu.like_spotify

import android.content.SharedPreferences
import org.json.JSONObject
import java.io.BufferedReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * The one Google `refresh_token` exchange on the native side, shared by
 * everything that holds a Google device-flow sign-in.
 *
 * There are two such sign-ins, each with its own OAuth client, its own tokens
 * and its own scope — YouTube Music ([YTMUSIC]) and the shared like counter's
 * spreadsheet ([COUNTER]) — so which prefs keys to read and write is the only
 * thing that varies. Callers decide what a failure means for them: this object
 * throws [RefreshFailure] and never notifies or logs.
 */
object GoogleTokens {
    /** Refresh this long before the access token actually expires. */
    const val REFRESH_MARGIN_MS = 5 * 60_000L

    /**
     * What a Google access token is worth when the refresh answer leaves
     * `expires_in` out: Google's own hour, the same figure the Dart half
     * falls back to (`GoogleTokenResponse.fromJson`).
     *
     * Storing an assumed expiry beats storing none: with [needsRefresh]
     * treating "no expiry" as "refresh now", a missing `expires_in` would
     * otherwise mean a token exchange on every single like.
     */
    const val DEFAULT_EXPIRES_IN_SEC = 3600L

    private const val HTTP_TIMEOUT_MS = 10_000

    /** Which prefs keys hold one sign-in's client and tokens. */
    data class Keys(
        val accessToken: String,
        val refreshToken: String,
        val expiresAt: String,
        val clientId: String,
        val clientSecret: String,
    )

    val YTMUSIC = Keys(
        accessToken = AppConstants.KEY_YTM_ACCESS_TOKEN,
        refreshToken = AppConstants.KEY_YTM_REFRESH_TOKEN,
        expiresAt = AppConstants.KEY_YTM_TOKEN_EXPIRES_AT,
        clientId = AppConstants.KEY_YTM_CLIENT_ID,
        clientSecret = AppConstants.KEY_YTM_CLIENT_SECRET,
    )

    val COUNTER = Keys(
        accessToken = AppConstants.KEY_COUNTER_ACCESS_TOKEN,
        refreshToken = AppConstants.KEY_COUNTER_REFRESH_TOKEN,
        expiresAt = AppConstants.KEY_COUNTER_TOKEN_EXPIRES_AT,
        clientId = AppConstants.KEY_COUNTER_CLIENT_ID,
        clientSecret = AppConstants.KEY_COUNTER_CLIENT_SECRET,
    )

    /**
     * A refresh that did not produce a token. [needsReauth] means the user has
     * to sign in again (revoked grant, missing client); anything else may work
     * on a later press. [error] is Google's own OAuth error code when it sent
     * one — `invalid_grant`, `invalid_client`, ... — because "sign in again"
     * and "your client secret is wrong" are both `needsReauth` and the caller
     * has to be able to tell the user which it was (#200).
     */
    class RefreshFailure(
        message: String,
        val httpCode: Int?,
        val needsReauth: Boolean,
        val error: String? = null,
    ) : Exception(message)

    /**
     * The stored access token for [keys], refreshed first when it is (nearly)
     * expired or [forceRefresh]. Blocking. Throws [RefreshFailure].
     */
    fun fresh(prefs: SharedPreferences, keys: Keys, forceRefresh: Boolean = false): String {
        val access = prefs.getString(keys.accessToken, null)
        val needsRefresh = needsRefresh(
            expiresAtMs = prefs.getLong(keys.expiresAt, 0L),
            nowMs = System.currentTimeMillis(),
            hasAccessToken = !access.isNullOrBlank(),
            forceRefresh = forceRefresh,
        )
        if (!needsRefresh && access != null) return access
        return refresh(prefs, keys)
    }

    /**
     * Whether the stored access token has to be exchanged before it is handed
     * out, given when it expires ([expiresAtMs], epoch millis).
     *
     * A missing expiry — `0L`, what [SharedPreferences.getLong] answers for a
     * key that was never written, and what `MainActivity` stores when the Dart
     * side has no expiry to send — reads as *unknown*, not *never expires*.
     * The other reading kept a stored token forever: no expiry meant never
     * stale, so the counter went on presenting a token that had died an hour
     * ago and every like fell back to the local tally. Unknown is cheap to be
     * wrong about (one refresh, and the answer carries an expiry, so at most
     * one per hour), and "fresh forever" is not.
     */
    fun needsRefresh(
        expiresAtMs: Long,
        nowMs: Long,
        hasAccessToken: Boolean,
        forceRefresh: Boolean = false,
    ): Boolean {
        if (forceRefresh || !hasAccessToken) return true
        if (expiresAtMs <= 0L) return true
        return expiresAtMs - nowMs < REFRESH_MARGIN_MS
    }

    /** Google's OAuth `error` code in a token-endpoint error body, if any. */
    fun oauthError(body: String?): String? =
        runCatching { JSONObject(body.orEmpty()).optString("error") }
            .getOrNull()
            ?.takeIf { it.isNotBlank() }

    /** Exchanges the stored refresh token, storing what comes back. */
    fun refresh(prefs: SharedPreferences, keys: Keys): String {
        val refreshToken = prefs.getString(keys.refreshToken, null)
        val clientId = prefs.getString(keys.clientId, null)
        val clientSecret = prefs.getString(keys.clientSecret, null)
        if (refreshToken.isNullOrBlank() || clientId.isNullOrBlank()) {
            throw RefreshFailure("Google sign-in incomplete", null, needsReauth = true)
        }

        val connection = URL(YouTubeDataApi.TOKEN_URL).openConnection() as HttpURLConnection
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.connectTimeout = HTTP_TIMEOUT_MS
        connection.readTimeout = HTTP_TIMEOUT_MS
        connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        val form = buildString {
            append("grant_type=refresh_token")
            append("&refresh_token=").append(URLEncoder.encode(refreshToken, Charsets.UTF_8.name()))
            append("&client_id=").append(URLEncoder.encode(clientId, Charsets.UTF_8.name()))
            if (!clientSecret.isNullOrBlank()) {
                append("&client_secret=").append(URLEncoder.encode(clientSecret, Charsets.UTF_8.name()))
            }
        }
        OutputStreamWriter(connection.outputStream).use { it.write(form) }

        val status = connection.responseCode
        if (status !in 200..299) {
            val body = readBody(connection, error = true)
            val reauth =
                YouTubeDataApi.classifyTokenError(status, body) == YouTubeDataApi.ErrorKind.REAUTH_REQUIRED
            throw RefreshFailure(
                if (reauth) "Google sign-in revoked" else "Google token refresh failed",
                status,
                needsReauth = reauth,
                error = oauthError(body),
            )
        }

        val json = JSONObject(readBody(connection, error = false).orEmpty())
        val access = json.optString("access_token")
        if (access.isBlank()) {
            throw RefreshFailure("Google token refresh returned no token", status, needsReauth = false)
        }
        val editor = prefs.edit().putString(keys.accessToken, access)
        json.optString("refresh_token").takeIf { it.isNotBlank() }?.let {
            editor.putString(keys.refreshToken, it)
        }
        // Always an expiry, even when Google left `expires_in` out: with no
        // expiry stored the token now reads as "age unknown, refresh it", so
        // omitting it would mean an exchange per like rather than per hour.
        val expiresIn = json.optLong("expires_in", 0L).takeIf { it > 0L } ?: DEFAULT_EXPIRES_IN_SEC
        editor.putLong(keys.expiresAt, System.currentTimeMillis() + expiresIn * 1000L)
        editor.apply()
        return access
    }

    private fun readBody(connection: HttpURLConnection, error: Boolean): String? = try {
        val stream = if (error) connection.errorStream else connection.inputStream
        stream?.let { BufferedReader(it.reader()).use { reader -> reader.readText() } }
    } catch (_: Exception) {
        null
    }
}
