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
     * on a later press.
     */
    class RefreshFailure(
        message: String,
        val httpCode: Int?,
        val needsReauth: Boolean,
    ) : Exception(message)

    /**
     * The stored access token for [keys], refreshed first when it is (nearly)
     * expired or [forceRefresh]. Blocking. Throws [RefreshFailure].
     */
    fun fresh(prefs: SharedPreferences, keys: Keys, forceRefresh: Boolean = false): String {
        val access = prefs.getString(keys.accessToken, null)
        val expiresAt = prefs.getLong(keys.expiresAt, 0L)
        val stale = expiresAt > 0L && expiresAt - System.currentTimeMillis() < REFRESH_MARGIN_MS
        if (!forceRefresh && !stale && !access.isNullOrBlank()) return access
        return refresh(prefs, keys)
    }

    /**
     * [fresh] for callers with nowhere to report a failure: null when there is
     * no usable token, for any reason.
     */
    fun freshOrNull(prefs: SharedPreferences, keys: Keys): String? = try {
        fresh(prefs, keys).takeIf { it.isNotBlank() }
    } catch (_: Exception) {
        null
    }

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
        val expiresIn = json.optLong("expires_in", 0L)
        if (expiresIn > 0L) {
            editor.putLong(keys.expiresAt, System.currentTimeMillis() + expiresIn * 1000L)
        }
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
