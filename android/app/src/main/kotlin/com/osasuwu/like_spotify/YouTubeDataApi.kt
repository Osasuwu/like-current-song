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
    data class SearchCandidate(val videoId: String, val channelTitle: String)

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
            val channel = item.optJSONObject("snippet")?.optString("channelTitle").orEmpty()
            out += SearchCandidate(videoId, channel)
        }
        return out
    }

    /**
     * Prefers the "Artist - Topic" Art Track (the audio-only upload YouTube
     * Music itself plays), then any upload from a channel named after the
     * artist, then the top hit. Null when there are no candidates.
     */
    fun pickVideo(candidates: List<SearchCandidate>, artist: String): String? {
        if (candidates.isEmpty()) return null
        val want = artist.trim().lowercase()
        if (want.isNotEmpty()) {
            val topic = "$want${TOPIC_SUFFIX.lowercase()}"
            candidates.firstOrNull { it.channelTitle.lowercase() == topic }?.let { return it.videoId }
            candidates.firstOrNull { it.channelTitle.lowercase().startsWith(want) }?.let { return it.videoId }
        }
        return candidates.first().videoId
    }

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

    /** Classifies a failed refresh at the OAuth token endpoint. */
    fun classifyTokenError(status: Int, body: String?): ErrorKind {
        val error = runCatching { JSONObject(body.orEmpty()).optString("error") }.getOrNull()
        return when {
            // invalid_grant: refresh token revoked or expired. invalid_client /
            // unauthorized_client: the OAuth client it was issued to is gone.
            error in REAUTH_TOKEN_ERRORS -> ErrorKind.REAUTH_REQUIRED
            status >= 500 -> ErrorKind.TRANSIENT
            else -> ErrorKind.FAILED
        }
    }

    /** `error.errors[0].reason` of a Google API error body, if any. */
    fun errorReason(body: String?): String? {
        if (body.isNullOrBlank()) return null
        return runCatching {
            val errors = JSONObject(body).optJSONObject("error")?.optJSONArray("errors")
            errors?.optJSONObject(0)?.optString("reason")?.takeIf { it.isNotBlank() }
        }.getOrNull()
    }

    private val RATE_LIMIT_REASONS = setOf("quotaExceeded", "rateLimitExceeded")
    private val REAUTH_TOKEN_ERRORS = setOf("invalid_grant", "invalid_client", "unauthorized_client")
}
