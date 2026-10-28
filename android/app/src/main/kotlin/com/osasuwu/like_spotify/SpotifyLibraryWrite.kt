package com.osasuwu.like_spotify

import java.io.BufferedReader
import java.net.HttpURLConnection
import org.json.JSONArray
import org.json.JSONObject

/**
 * The outcome of one Spotify write.
 *
 * [errorBody] carries Spotify's own error payload on a failed write, so a log
 * line can say *why* instead of only how many.
 */
internal data class ApiResult(
    val success: Boolean,
    val statusCode: Int,
    val errorBody: String? = null
)

/**
 * The `/me/library` save, unsave and contains calls and their one legacy
 * fallback, kept apart from
 * [SpotifyLikeWorker] so the decision it encodes is exercised by JVM unit tests
 * instead of only by a phone: nothing here touches an Android API, and the
 * connections themselves are supplied by the caller.
 *
 * See [SpotifyLibraryEndpoints] for why both endpoint forms have to keep
 * working, and which status codes earn the retry.
 */
internal object SpotifyLibraryWrite {

    /**
     * Saves/follows [uri] through the generic `PUT /me/library` endpoint
     * ([generic] receives the URL to open), running [legacy] once when that
     * endpoint is not available to this client ID (see
     * [SpotifyLibraryEndpoints.shouldTryLegacy]). A successful legacy call is
     * remembered for the process lifetime, so only the first write of a session
     * pays two round trips.
     *
     * The URI travels in the query string — see
     * [SpotifyLibraryEndpoints.libraryUrl]; a JSON body gets a 400. On failure
     * the response body comes back in [ApiResult.errorBody] so Spotify's own
     * `{"error":{"message":…}}` reaches the log instead of a bare number.
     */
    fun saveToLibrary(
        uri: String,
        generic: (url: String) -> HttpURLConnection,
        legacy: () -> HttpURLConnection
    ): ApiResult = write(uri, generic, legacy)

    /**
     * Unsaves/unfollows [uri] through `DELETE /me/library`, for the undo
     * (#267). The fallback is [saveToLibrary]'s: the HTTP method lives in the
     * connections the caller opens, not in the decision.
     */
    fun removeFromLibrary(
        uri: String,
        generic: (url: String) -> HttpURLConnection,
        legacy: () -> HttpURLConnection
    ): ApiResult = write(uri, generic, legacy)

    /**
     * Whether [uri] is in the library, through `GET /me/library/contains` and
     * the same one fallback. Null when no readable answer came back: a caller
     * that read that as "not saved" could later unsave a track the user had
     * saved themselves.
     */
    fun contains(
        uri: String,
        generic: (url: String) -> HttpURLConnection,
        legacy: () -> HttpURLConnection
    ): Boolean? {
        if (!SpotifyLibraryEndpoints.useLegacyEndpoints) {
            val connection = generic(SpotifyLibraryEndpoints.containsUrl(uri))
            val code = connection.responseCode
            if (code in 200..299) return parseContains(readBody(connection), uri)
            if (!SpotifyLibraryEndpoints.shouldTryLegacy(code)) return null
        }

        val legacyConnection = legacy()
        if (legacyConnection.responseCode !in 200..299) return null
        SpotifyLibraryEndpoints.rememberLegacyEndpoints()
        return parseContains(readBody(legacyConnection), uri)
    }

    /**
     * The answer for [uri] in a contains response. The legacy endpoint answers
     * with one boolean per id, in order; the migration guide documents only
     * the request side of `/me/library/contains`, so a map keyed by URI is
     * read as well, as the desktop's `_contains_flag` does.
     */
    private fun parseContains(body: String?, uri: String): Boolean? {
        val text = body?.trim() ?: return null
        return try {
            if (text.startsWith("{")) {
                JSONObject(text).let { if (it.has(uri)) it.getBoolean(uri) else null }
            } else {
                JSONArray(text).let { if (it.length() > 0) it.getBoolean(0) else null }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun readBody(connection: HttpURLConnection): String? = try {
        BufferedReader(connection.inputStream.reader()).use { it.readText() }
    } catch (_: Exception) {
        null
    }

    private fun write(
        uri: String,
        generic: (url: String) -> HttpURLConnection,
        legacy: () -> HttpURLConnection
    ): ApiResult {
        if (!SpotifyLibraryEndpoints.useLegacyEndpoints) {
            // No body, no Content-Type: `uris` is a query parameter.
            val connection = generic(SpotifyLibraryEndpoints.libraryUrl(uri))
            val code = connection.responseCode
            if (code in 200..299) return ApiResult(true, code)
            if (!SpotifyLibraryEndpoints.shouldTryLegacy(code)) {
                return ApiResult(false, code, readErrorBody(connection))
            }
        }

        val legacyConnection = legacy()
        val legacyCode = legacyConnection.responseCode
        val ok = legacyCode in 200..299
        if (ok) SpotifyLibraryEndpoints.rememberLegacyEndpoints()
        return ApiResult(ok, legacyCode, if (ok) null else readErrorBody(legacyConnection))
    }

    /**
     * The error payload of a non-2xx response — Spotify answers with
     * `{"error":{"status":400,"message":…}}`, and a bare status code on its own
     * is not enough to diagnose a failed write.
     */
    fun readErrorBody(connection: HttpURLConnection): String? {
        return try {
            connection.errorStream
                ?.let { BufferedReader(it.reader()).use { reader -> reader.readText() } }
                ?.takeIf { it.isNotBlank() }
        } catch (_: Exception) {
            null
        }
    }
}
