package com.osasuwu.like_spotify

import org.json.JSONObject

/**
 * Pure helpers for the YouTube Data API fallback: no Android, no I/O, so the
 * JVM unit tests (`src/test`) cover them directly.
 *
 * The pick order and error classification mirror the desktop provider in
 * `like_spotify/extensions/ytmusic/__init__.py` (`_pick_video`,
 * `_raise_for_status`); keep the two in step.
 */
object YouTubeDataApi {
    const val API_BASE = "https://www.googleapis.com/youtube/v3"
    const val TOKEN_URL = "https://oauth2.googleapis.com/token"
    const val MUSIC_CATEGORY_ID = "10"
    const val SEARCH_MAX_RESULTS = 5
    private const val TOPIC_SUFFIX = " - Topic"

    /** One `search.list` hit: just what the pick order needs. */
    data class SearchCandidate(
        val videoId: String,
        val channelTitle: String,
        val channelId: String = "",
    )

    /**
     * The video a search resolved to, plus the artist's channel when the hit
     * came from the artist themselves — see [pickMatch].
     */
    data class Match(val videoId: String, val artistChannelId: String?)

    /** One `playlists.list` entry. */
    data class Playlist(val id: String, val title: String)

    /** What the caller should do about a non-2xx Data API response. */
    enum class ErrorKind {
        /** 401: the access token expired or was revoked; refresh once and retry. */
        TOKEN_EXPIRED,

        /** Daily quota / rate limit: report it, but the sign-in is fine. */
        RATE_LIMITED,

        /** The grant is unusable (other 403, `invalid_grant`): sign in again. */
        REAUTH_REQUIRED,

        /** Google-side error; a later press may work. */
        TRANSIENT,

        /** Anything else (bad request, not found, ...). */
        FAILED,
    }

    /**
     * Plain YouTube playback reports auto-generated channels as
     * "Artist - Topic"; the suffix only hurts the search.
     */
    fun cleanArtist(artist: String?): String {
        val trimmed = artist.orEmpty().trim()
        return if (trimmed.endsWith(TOPIC_SUFFIX)) {
            trimmed.removeSuffix(TOPIC_SUFFIX).trim()
        } else {
            trimmed
        }
    }

    /** The `q` parameter for `search.list`. */
    fun searchQuery(artist: String, title: String): String = "$artist $title".trim()

    /** Parses a `search.list` body; hits without a videoId are dropped. */
    fun parseSearchCandidates(body: String): List<SearchCandidate> {
        val items = runCatching { JSONObject(body).optJSONArray("items") }.getOrNull()
            ?: return emptyList()
        val out = mutableListOf<SearchCandidate>()
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            val videoId = item.optJSONObject("id")?.optString("videoId").orEmpty()
            if (videoId.isBlank()) continue
            val snippet = item.optJSONObject("snippet")
            val channel = snippet?.optString("channelTitle").orEmpty()
            val channelId = snippet?.optString("channelId").orEmpty()
            out += SearchCandidate(videoId, channel, channelId)
        }
        return out
    }

    /**
     * Prefers the "Artist - Topic" Art Track (the audio-only upload YouTube
     * Music itself plays), then any upload from a channel named after the
     * artist, then the top hit. Null when there are no candidates.
     *
     * [Match.artistChannelId] is only set for the first two: the top hit may
     * be a cover or a random upload, and auto-follow must never subscribe the
     * user to a stranger over a lucky search result.
     */
    fun pickMatch(candidates: List<SearchCandidate>, artist: String): Match? {
        if (candidates.isEmpty()) return null
        val want = artist.trim().lowercase()
        if (want.isNotEmpty()) {
            val topic = "$want${TOPIC_SUFFIX.lowercase()}"
            candidates.firstOrNull { it.channelTitle.lowercase() == topic }?.let { return it.byArtist() }
            candidates.firstOrNull { it.channelTitle.lowercase().startsWith(want) }?.let { return it.byArtist() }
        }
        return Match(candidates.first().videoId, artistChannelId = null)
    }

    private fun SearchCandidate.byArtist() = Match(videoId, channelId.takeIf { it.isNotBlank() })

    /** Parses a `playlists.list` body; entries without an id are dropped. */
    fun parsePlaylists(body: String): List<Playlist> {
        val items = runCatching { JSONObject(body).optJSONArray("items") }.getOrNull()
            ?: return emptyList()
        val out = mutableListOf<Playlist>()
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            val id = item.optString("id").orEmpty()
            if (id.isBlank()) continue
            out += Playlist(id, item.optJSONObject("snippet")?.optString("title").orEmpty())
        }
        return out
    }

    /** The page token for the next `list` page, or null on the last one. */
    fun nextPageToken(body: String): String? = runCatching {
        JSONObject(body).optString("nextPageToken").takeIf { it.isNotBlank() }
    }.getOrNull()

    /**
     * The id of the playlist called [name], case-insensitively — YouTube lets
     * two playlists share a title, so the first match wins, as on desktop.
     */
    fun findPlaylistId(playlists: List<Playlist>, name: String): String? {
        val want = name.trim().lowercase()
        if (want.isEmpty()) return null
        return playlists.firstOrNull { it.title.trim().lowercase() == want }?.id
    }

    /**
     * The playlistItem ids in a `playlistItems.list` body that hold [videoId].
     * A song can sit in a playlist more than once; every copy goes.
     */
    fun parsePlaylistItemIds(body: String, videoId: String): List<String> {
        val items = runCatching { JSONObject(body).optJSONArray("items") }.getOrNull()
            ?: return emptyList()
        val out = mutableListOf<String>()
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            val id = item.optString("id").orEmpty()
            if (id.isBlank()) continue
            if (item.optJSONObject("contentDetails")?.optString("videoId") != videoId) continue
            out += id
        }
        return out
    }

    /** The `id` of a just-created resource (`playlists.insert`), if any. */
    fun parseResourceId(body: String): String? = runCatching {
        JSONObject(body).optString("id").takeIf { it.isNotBlank() }
    }.getOrNull()

    /** Whether a failed `subscriptions.insert` just means "already subscribed". */
    fun isDuplicateSubscription(reason: String?): Boolean = reason == DUPLICATE_SUBSCRIPTION

    /** Classifies a non-2xx Data API response (`search.list`, `videos.rate`). */
    fun classifyApiError(status: Int, body: String?): ErrorKind = when {
        status == 401 -> ErrorKind.TOKEN_EXPIRED
        // YouTube reports an exhausted daily quota as 403, not 429.
        status == 403 && errorReason(body) in RATE_LIMIT_REASONS -> ErrorKind.RATE_LIMITED
        status == 403 -> ErrorKind.REAUTH_REQUIRED
        status == 429 -> ErrorKind.RATE_LIMITED
        status >= 500 -> ErrorKind.TRANSIENT
        else -> ErrorKind.FAILED
    }

    /**
     * Classifies a failed refresh at the OAuth token endpoint.
     *
     * [ErrorKind.REAUTH_REQUIRED] here means "signing in again fixes this",
     * so it is reserved for [REAUTH_TOKEN_ERRORS]; a client the endpoint
     * turned down is [isRejectedClient] instead, and the caller has to say
     * what to check rather than ask for a sign-in that would present the
     * same rejected client (#204).
     */
    fun classifyTokenError(status: Int, body: String?): ErrorKind {
        val error = runCatching { JSONObject(body.orEmpty()).optString("error") }.getOrNull()
        return when {
            error in REAUTH_TOKEN_ERRORS -> ErrorKind.REAUTH_REQUIRED
            status >= 500 -> ErrorKind.TRANSIENT
            else -> ErrorKind.FAILED
        }
    }

    /**
     * Whether the token endpoint turned down the OAuth client itself — a
     * client ID or secret that is wrong, deleted, or of the wrong type —
     * rather than the grant it was asked to exchange.
     */
    fun isRejectedClient(error: String?): Boolean = error in REJECTED_CLIENT_ERRORS

    /** `error.errors[0].reason` of a Google API error body, if any. */
    fun errorReason(body: String?): String? {
        if (body.isNullOrBlank()) return null
        return runCatching {
            val errors = JSONObject(body).optJSONObject("error")?.optJSONArray("errors")
            errors?.optJSONObject(0)?.optString("reason")?.takeIf { it.isNotBlank() }
        }.getOrNull()
    }

    private const val DUPLICATE_SUBSCRIPTION = "subscriptionDuplicate"
    private val RATE_LIMIT_REASONS = setOf("quotaExceeded", "rateLimitExceeded")
    /**
     * The one refusal a new sign-in fixes: the refresh token itself is gone —
     * revoked, password changed, six months unused, or the Testing-mode
     * consent screen's 7-day limit — so a fresh grant replaces it.
     *
     * The Dart half draws the line in the same place: `GoogleDeviceFlow.refresh`
     * (`lib/data/google/google_device_flow.dart`) raises `GoogleSignInRevoked`
     * for `invalid_grant` and nothing else. The two have to agree, because
     * both halves refresh the same stored tokens: a rule that differed would
     * have the app sign itself out over a refusal the service kept living
     * with, or the other way round (#204).
     */
    private val REAUTH_TOKEN_ERRORS = setOf("invalid_grant")

    /**
     * The refusals a new sign-in cannot fix, because it would present the
     * same rejected client. These need the client ID and secret checked, and
     * saying "sign in again" instead is the loop #200 was about.
     */
    private val REJECTED_CLIENT_ERRORS = setOf("invalid_client", "unauthorized_client")
}
