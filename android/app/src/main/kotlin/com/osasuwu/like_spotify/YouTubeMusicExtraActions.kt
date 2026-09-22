package com.osasuwu.like_spotify

import android.content.SharedPreferences
import org.json.JSONObject
import java.net.URLEncoder

/**
 * The opt-in actions that follow a YouTube Music like: drop the song from an
 * archive playlist, promote it to a best playlist once it has been liked
 * often enough, and subscribe to the artist's channel once they have. The
 * Spotify twins live in [SpotifyLikeWorker]; the semantics come from the
 * desktop provider (`like_spotify/extensions/ytmusic/__init__.py`).
 *
 * Quota: the Data API grants 10,000 units a day and every write costs 50
 * (`playlistItems.insert`/`delete`, `playlists.insert`, `subscriptions.insert`)
 * while a `list` costs 1 per page. Nothing here runs unless the user turned an
 * action on, the caller hands over the videoId the like already resolved
 * instead of searching again (100 units), and playlist ids are cached for
 * [AppConstants.PLAYLIST_CACHE_TTL_MS] — so a steady-state like spends one
 * write per enabled action.
 *
 * Every action is best-effort: the like is the product, so a failure here is
 * logged and nothing else.
 */
class YouTubeMusicExtraActions(
    private val prefs: SharedPreferences,
    /** `(method, url, jsonBody) -> response body`; throws [ApiFailure] on a non-2xx. */
    private val apiCall: (method: String, url: String, body: String?) -> String,
    private val log: (message: String, actionType: String, result: String, httpCode: Int?) -> Unit,
) {
    private val rules = loadRules()

    /** Whether any action is on — false means the caller can skip the lookup entirely. */
    fun anyEnabled(): Boolean =
        (rules.archiveRemoveEnabled && rules.archivePlaylistName.isNotBlank()) ||
            (rules.bestEnabled && rules.bestPlaylistName.isNotBlank()) ||
            rules.followArtistEnabled

    /**
     * Runs the enabled actions for a like that went through. [sharedLikeCount]
     * is the shared counter's answer for this song, or null when it was not
     * counted (no sign-in, no counter sheet, counter unreachable).
     */
    fun run(match: YouTubeDataApi.Match, sharedLikeCount: Int?) {
        if (rules.archiveRemoveEnabled && rules.archivePlaylistName.isNotBlank()) {
            runCatching { archiveRemove(rules.archivePlaylistName, match.videoId) }
                .onFailure { report("Archive removal failed", ARCHIVE_ACTION, it) }
        }

        if (rules.bestEnabled && rules.bestPlaylistName.isNotBlank()) {
            // The shared counter already counted this like; the local map is
            // only the fallback for when there is no counter to ask.
            val count = sharedLikeCount ?: incrementLocalCount(LocalCounters.Kind.TRACK, match.videoId)
            if (reachedThreshold(count, rules.bestThreshold)) {
                runCatching { promoteToBest(rules.bestPlaylistName, match.videoId) }
                    .onFailure { report("Best promotion failed", BEST_ACTION, it) }
            }
        }

        if (rules.followArtistEnabled) {
            // Only the artist's own channel: see YouTubeDataApi.pickMatch.
            val channelId = match.artistChannelId
            if (channelId == null) {
                log("Auto-follow skipped: the match is not the artist's own channel", FOLLOW_ACTION, "info", null)
            } else {
                val followedKey = countKey(channelId)
                val count = incrementLocalCount(LocalCounters.Kind.ARTIST, channelId)
                if (shouldFollow(count, rules.followArtistThreshold, followedKey)) {
                    runCatching {
                        followChannel(channelId)
                        LocalCounters.markArtistFollowed(prefs, followedKey)
                    }.onFailure { report("Follow artist failed", FOLLOW_ACTION, it) }
                }
            }
        }
    }

    // ---- Actions -------------------------------------------------

    private fun archiveRemove(name: String, videoId: String) {
        val playlistId = findPlaylist(name)
        if (playlistId == null) {
            log("Archive removal skipped: no playlist named \"$name\"", ARCHIVE_ACTION, "info", null)
            return
        }
        val fields = encode("items(id,contentDetails/videoId)")
        val body = apiCall(
            "GET",
            "${YouTubeDataApi.API_BASE}/playlistItems?part=contentDetails" +
                "&playlistId=${encode(playlistId)}&videoId=${encode(videoId)}" +
                "&maxResults=$PAGE_SIZE&fields=$fields",
            null,
        )
        val itemIds = YouTubeDataApi.parsePlaylistItemIds(body, videoId)
        if (itemIds.isEmpty()) {
            log("Archive removal skipped: not in \"$name\"", ARCHIVE_ACTION, "info", null)
            return
        }
        itemIds.forEach {
            apiCall("DELETE", "${YouTubeDataApi.API_BASE}/playlistItems?id=${encode(it)}", null)
        }
        log("Removed from archive playlist: $name", ARCHIVE_ACTION, "success", null)
    }

    /**
     * Adds [videoId] to the user's playlist called [name], creating it if they
     * have none, and logs it as [actionType] saying [what] — or, when [what]
     * is null, logs nothing because the caller reports the result itself.
     *
     * Shared with the like path: a like whose destination is a playlist adds
     * the song exactly the way the best-playlist rule does, so there is one
     * implementation of "put this song in that playlist of mine" rather than
     * two that can drift. Throws [ApiFailure] when the API refuses; returns
     * false when the playlist could neither be found nor created.
     */
    fun addToPlaylist(name: String, videoId: String, actionType: String, what: String?): Boolean {
        val playlistId = ensurePlaylist(name, actionType) ?: return false
        val body = JSONObject().put(
            "snippet",
            JSONObject()
                .put("playlistId", playlistId)
                .put(
                    "resourceId",
                    JSONObject().put("kind", "youtube#video").put("videoId", videoId),
                ),
        ).toString()
        apiCall("POST", "${YouTubeDataApi.API_BASE}/playlistItems?part=snippet", body)
        if (what != null) log("$what: $name", actionType, "success", null)
        return true
    }

    private fun promoteToBest(name: String, videoId: String) {
        addToPlaylist(name, videoId, BEST_ACTION, "Added to best playlist")
    }

    private fun followChannel(channelId: String) {
        val body = JSONObject().put(
            "snippet",
            JSONObject().put(
                "resourceId",
                JSONObject().put("kind", "youtube#channel").put("channelId", channelId),
            ),
        ).toString()
        try {
            apiCall("POST", "${YouTubeDataApi.API_BASE}/subscriptions?part=snippet", body)
        } catch (failure: ApiFailure) {
            // Subscribing twice is a 400, not a no-op: the user got there first.
            if (!YouTubeDataApi.isDuplicateSubscription(failure.reason)) throw failure
            log("Already subscribed to the artist's channel: $channelId", FOLLOW_ACTION, "info", null)
            return
        }
        log("Auto-followed artist channel: $channelId", FOLLOW_ACTION, "success", null)
    }

    // ---- Playlist lookup / creation -------------------------------------------------

    /** The id of the user's playlist called [name], or null when they have none. */
    private fun findPlaylist(name: String): String? {
        val cache = loadPlaylistCache()
        cache.keys().forEach { key ->
            if (key.equals(name, ignoreCase = true)) {
                cache.optString(key).takeIf { it.isNotBlank() }?.let { return it }
            }
        }

        var pageToken: String? = null
        while (true) {
            val fields = encode("items(id,snippet/title),nextPageToken")
            val body = apiCall(
                "GET",
                "${YouTubeDataApi.API_BASE}/playlists?part=snippet&mine=true" +
                    "&maxResults=$PAGE_SIZE&fields=$fields" +
                    (pageToken?.let { "&pageToken=${encode(it)}" } ?: ""),
                null,
            )
            val page = YouTubeDataApi.parsePlaylists(body)
            // Remember the whole page: two actions in one like then share a lookup.
            page.forEach { cache.put(it.title, it.id) }
            savePlaylistCache(cache)
            YouTubeDataApi.findPlaylistId(page, name)?.let { return it }
            pageToken = YouTubeDataApi.nextPageToken(body) ?: return null
        }
    }

    private fun ensurePlaylist(name: String, actionType: String): String? {
        findPlaylist(name)?.let { return it }

        val body = JSONObject()
            .put("snippet", JSONObject().put("title", name).put("description", PLAYLIST_DESCRIPTION))
            .put("status", JSONObject().put("privacyStatus", "private"))
            .toString()
        // Invalidate before creating, so a concurrent rebuild can't miss the new playlist.
        savePlaylistCache(JSONObject())
        val id = YouTubeDataApi.parseResourceId(
            apiCall("POST", "${YouTubeDataApi.API_BASE}/playlists?part=snippet,status", body)
        ) ?: return null
        savePlaylistCache(loadPlaylistCache().put(name, id))
        log("Created playlist: $name", actionType, "success", null)
        return id
    }

    private fun loadPlaylistCache(): JSONObject {
        val timestamp = prefs.getLong(AppConstants.KEY_YTM_PLAYLIST_CACHE_TIMESTAMP, 0L)
        if (System.currentTimeMillis() - timestamp > AppConstants.PLAYLIST_CACHE_TTL_MS) return JSONObject()
        val raw = prefs.getString(AppConstants.KEY_YTM_PLAYLIST_CACHE, null) ?: return JSONObject()
        return runCatching { JSONObject(raw) }.getOrDefault(JSONObject())
    }

    private fun savePlaylistCache(cache: JSONObject) {
        prefs.edit()
            .putString(AppConstants.KEY_YTM_PLAYLIST_CACHE, cache.toString())
            .putLong(AppConstants.KEY_YTM_PLAYLIST_CACHE_TIMESTAMP, System.currentTimeMillis())
            .apply()
    }

    // ---- Local counting -------------------------------------------------

    /**
     * The local like count for [id], one higher than before. Kept apart from
     * Spotify's ids in the same map by [countKey].
     */
    private fun incrementLocalCount(kind: LocalCounters.Kind, id: String): Int =
        LocalCounters.increment(prefs, kind, countKey(id))

    /**
     * Whether to subscribe to [followedKey]'s channel now, by the same rule the
     * Spotify worker follows by -- [LocalCounters.shouldFollow] is where that
     * rule lives and where it is tested.
     *
     * Deliberately not [reachedThreshold], which the best-playlist rule shares
     * and which fires on the exact count. Follow is the rule #197 broke -- a
     * count that skipped past the threshold because the two stores were
     * separate could never equal it again -- so it gets its own condition and
     * the best rule keeps the behaviour it has.
     */
    private fun shouldFollow(count: Int, threshold: Int, followedKey: String): Boolean =
        LocalCounters.shouldFollow(count, threshold, LocalCounters.followedArtists(prefs), followedKey)

    // ---- Rule config -------------------------------------------------

    private data class Rules(
        val archiveRemoveEnabled: Boolean,
        val archivePlaylistName: String,
        val bestEnabled: Boolean,
        val bestPlaylistName: String,
        val bestThreshold: Int,
        val followArtistEnabled: Boolean,
        val followArtistThreshold: Int,
    )

    // Same keys and fallbacks as the Spotify path (SpotifyLikeWorker
    // .loadRuleConfig): the rules are the user's, not the service's.
    private fun loadRules() = Rules(
        archiveRemoveEnabled = prefs.getBoolean(AppConstants.KEY_RULE_ARCHIVE_REMOVE_ENABLED, false),
        archivePlaylistName = prefs.getString(AppConstants.KEY_RULE_ARCHIVE_PLAYLIST_NAME, null)?.trim().orEmpty(),
        bestEnabled = AppConstants.bestRuleEnabled(prefs),
        bestPlaylistName = AppConstants.bestRulePlaylistName(prefs),
        bestThreshold = AppConstants.bestRuleThreshold(prefs),
        followArtistEnabled = prefs.getBoolean(AppConstants.KEY_RULE_FOLLOW_ARTIST_ENABLED, false),
        followArtistThreshold = prefs.getInt(
            AppConstants.KEY_RULE_FOLLOW_ARTIST_THRESHOLD,
            AppConstants.DEFAULT_FOLLOW_ARTIST_THRESHOLD,
        ).takeIf { it >= 1 } ?: AppConstants.DEFAULT_FOLLOW_ARTIST_THRESHOLD,
    )

    // ---- Logging -------------------------------------------------

    private fun report(what: String, actionType: String, error: Throwable) {
        val failure = error as? ApiFailure
        log("$what: ${failure?.outcomeError ?: error.message}", actionType, "failure", failure?.httpCode)
    }

    private fun encode(value: String): String = URLEncoder.encode(value, Charsets.UTF_8.name())

    companion object {
        private const val PAGE_SIZE = 50
        // Same wording the desktop YouTube Music provider and the Spotify path
        // write — a playlist this app manages says so the same way everywhere.
        private const val PLAYLIST_DESCRIPTION = "Managed by Like Current Song"

        /** Log action types, shared with the Spotify pipeline so the log screen groups them. */
        private const val ARCHIVE_ACTION = "archive_remove"
        private const val BEST_ACTION = "best_add"
        private const val FOLLOW_ACTION = "follow_artist"

        /**
         * The like's own playlist leg. Public because the liker runs that leg
         * itself — it is part of the like, not an action that follows one.
         */
        const val LIKE_PLAYLIST_ACTION = "like_playlist_add"

        /**
         * A threshold action fires the once, exactly when the count reaches it
         * — not on every like after. Same rule as the Spotify pipeline.
         */
        fun reachedThreshold(count: Int, threshold: Int): Boolean = count == threshold

        /**
         * Key for the local count maps, which the Spotify pipeline writes too.
         * YouTube ids look nothing like Spotify's, but they share a namespace,
         * and an accidental overlap would count someone else's likes.
         */
        fun countKey(id: String): String = "ytmusic:$id"
    }
}
