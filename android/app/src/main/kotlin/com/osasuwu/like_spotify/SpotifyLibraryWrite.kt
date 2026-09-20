package com.osasuwu.like_spotify

import java.io.BufferedReader
import java.net.HttpURLConnection

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
 * The `PUT /me/library` write and its one legacy fallback, kept apart from
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
