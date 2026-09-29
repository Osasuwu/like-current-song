package com.osasuwu.like_spotify

import android.content.SharedPreferences
import org.json.JSONObject

/**
 * The Spotify playlist name-to-id cache the background worker resolves
 * playlists through, so a like does not enumerate every playlist the user owns.
 * The whole blob expires [AppConstants.PLAYLIST_CACHE_TTL_MS] after it was last
 * written.
 *
 * Lives apart from [SpotifyLikeWorker] because a `Worker` needs a `Context` the
 * plain-JUnit suite cannot supply, while this needs nothing but a
 * [SharedPreferences] (#189). Its Dart twin is the cache in
 * `lib/data/spotify/spotify_playlist_service.dart`; the two are meant to stay
 * in step, the stale-id recovery (#187) included.
 */
object PlaylistCache {

    /**
     * The cached name-to-id map. An expired, absent or unreadable blob reads
     * as empty -- a lost cache only costs one enumeration, never a like.
     */
    fun load(prefs: SharedPreferences, now: Long = System.currentTimeMillis()): JSONObject {
        val timestamp = prefs.getLong(AppConstants.KEY_PLAYLIST_CACHE_TIMESTAMP, 0L)
        if (now - timestamp > AppConstants.PLAYLIST_CACHE_TTL_MS) return JSONObject()
        val raw = prefs.getString(AppConstants.KEY_PLAYLIST_CACHE, null) ?: return JSONObject()
        return try {
            JSONObject(raw)
        } catch (_: Exception) {
            JSONObject()
        }
    }

    /** Stores [cache] and restarts its TTL. */
    fun save(prefs: SharedPreferences, cache: JSONObject, now: Long = System.currentTimeMillis()) {
        prefs.edit()
            .putString(AppConstants.KEY_PLAYLIST_CACHE, cache.toString())
            .putLong(AppConstants.KEY_PLAYLIST_CACHE_TIMESTAMP, now)
            .apply()
    }

    /** The id cached under [name], matched case-insensitively; null when there is none. */
    fun find(cache: JSONObject, name: String): String? {
        cache.keys().forEach { key ->
            if (key.equals(name, ignoreCase = true)) {
                cache.optString(key).takeIf { it.isNotBlank() }?.let { return it }
            }
        }
        return null
    }

    /**
     * Drops every cached id filed under [name]. Called when Spotify answers a
     * cached id with 404: the playlist it names is gone, and re-enumerating
     * would not remove the entry by itself -- a deleted playlist simply never
     * comes back in the listing, leaving the dead id in place until the cache
     * TTL expires.
     */
    fun forget(prefs: SharedPreferences, name: String, now: Long = System.currentTimeMillis()) {
        val cache = load(prefs, now)
        val doomed = cache.keys().asSequence().filter { it.equals(name, ignoreCase = true) }.toList()
        if (doomed.isEmpty()) return
        doomed.forEach { cache.remove(it) }
        save(prefs, cache, now)
    }
}
