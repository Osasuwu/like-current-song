package com.osasuwu.like_spotify

/**
 * Where the background like lands, after Spotify's February 2026 API migration
 * replaced `PUT /me/tracks`, `PUT /me/following` and friends with one generic
 * `PUT /me/library` that takes Spotify URIs in a JSON body.
 *
 * Client IDs registered before 2026-02-11 were grandfathered onto the
 * entity-specific endpoints, so both forms have to keep working: the caller
 * tries the generic endpoint and falls back once when it is not available to
 * this client. The Dart twin lives in `lib/data/spotify/spotify_client.dart`
 * and the desktop one in `like_spotify/extensions/spotify/__init__.py`.
 */
object SpotifyLibraryEndpoints {

    const val LIBRARY_URL: String = "https://api.spotify.com/v1/me/library"

    fun trackUri(trackId: String): String = "spotify:track:$trackId"

    fun artistUri(artistId: String): String = "spotify:artist:$artistId"

    /**
     * Whether [statusCode] from `/me/library` means "this client cannot use the
     * generic endpoint", so the endpoint it replaced is worth one retry:
     *
     *  * **404** — the generic path is not routed for this client at all.
     *  * **403** — Spotify's restricted-access model answers endpoints outside
     *    a client's granted set with Forbidden, which is what a client ID
     *    grandfathered onto the entity-specific endpoints sees here.
     *
     * Deliberately excluded: **401** (token — must surface so the caller
     * refreshes), **429** (rate limit — must surface unchanged), **400** (our
     * own payload; a retry cannot fix it) and **5xx** (transient). A 403 caused
     * by a missing scope rather than by endpoint access fails on both forms,
     * and since the fallback is only remembered once the legacy call succeeds
     * ([rememberLegacyEndpoints]), such a 403 never pins the process to the
     * legacy endpoints.
     */
    fun shouldTryLegacy(statusCode: Int): Boolean = statusCode == 403 || statusCode == 404

    @Volatile
    private var legacyInUse: Boolean = false

    /**
     * True once a legacy endpoint has answered in `/me/library`'s place, so the
     * rest of the process skips the doomed first request. Process-wide on
     * purpose: the answer depends on the client ID, not on the worker instance.
     */
    val useLegacyEndpoints: Boolean
        get() = legacyInUse

    fun rememberLegacyEndpoints() {
        legacyInUse = true
    }

    /** Forgets the decision. Tests only — it is meant to live for the process. */
    fun resetForTesting() {
        legacyInUse = false
    }
}
