package com.osasuwu.like_spotify

import android.content.SharedPreferences
import org.json.JSONObject
import java.io.BufferedReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

/**
 * The cross-device like counter: the Supabase `increment_track_like` RPC
 * (schema in `docs/supabase-setup.sql`), shared with the Dart layer and the
 * desktop app. A row is keyed by (user id, track id), where both ids come from
 * the music service the like went through, so the phone and the computer add
 * to the same count per account.
 */
object LikeCounter {
    private const val HTTP_TIMEOUT_MS = 5_000

    /** Where one like is counted. */
    data class Target(val supabaseUrl: String, val anonKey: String, val userId: String)

    /**
     * The account id that keys the counter for a like made through [provider]:
     * the Spotify user id, or the Google account's id_token `sub` for YouTube
     * Music (the key desktop YouTube Music uses). Null when that service has
     * no account id, i.e. the user is not signed in there.
     *
     * Mirrors `likeCounterUserId` in `lib/domain/services/like_counter_user_id.dart`.
     */
    fun userIdFor(provider: MusicProvider, spotifyUserId: String?, ytmUserSub: String?): String? {
        val id = when (provider) {
            MusicProvider.SPOTIFY -> spotifyUserId
            MusicProvider.YTMUSIC -> ytmUserSub
        }
        return id?.trim()?.takeIf { it.isNotEmpty() }
    }

    /** The counter target for [provider], or null when Supabase is not configured or there is no user id. */
    fun target(prefs: SharedPreferences, provider: MusicProvider): Target? {
        val url = prefs.getString(AppConstants.KEY_SUPABASE_URL, null)?.trim()
        val key = prefs.getString(AppConstants.KEY_SUPABASE_ANON_KEY, null)?.trim()
        if (url.isNullOrEmpty() || key.isNullOrEmpty()) return null
        val userId = userIdFor(
            provider,
            spotifyUserId = prefs.getString(AppConstants.KEY_SPOTIFY_USER_ID, null),
            ytmUserSub = prefs.getString(AppConstants.KEY_YTM_USER_SUB, null),
        ) ?: return null
        return Target(url, key, userId)
    }

    /**
     * JSON body for the RPC. `p_was_already_liked` is sent only when true: the
     * RPC defaults it to false, and leaving it out keeps Spotify's request
     * exactly as before (and working against a pre-#24 schema).
     */
    fun requestBody(userId: String, trackId: String, wasAlreadyLiked: Boolean): String {
        val json = JSONObject()
            .put("p_user_id", userId)
            .put("p_track_id", trackId)
        if (wasAlreadyLiked) json.put("p_was_already_liked", true)
        return json.toString()
    }

    /** Parses the RPC's reply, the new count as a bare integer. */
    fun parseCount(body: String?): Int? = body?.trim()?.toIntOrNull()

    /**
     * Increments the count for [trackId] and returns the new count, or null on
     * any failure (non-2xx, network, unparseable reply). Blocking.
     */
    fun increment(target: Target, trackId: String, wasAlreadyLiked: Boolean = false): Int? {
        return try {
            val connection = URL("${target.supabaseUrl}/rest/v1/rpc/increment_track_like")
                .openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.connectTimeout = HTTP_TIMEOUT_MS
            connection.readTimeout = HTTP_TIMEOUT_MS
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("apikey", target.anonKey)
            connection.setRequestProperty("Authorization", "Bearer ${target.anonKey}")
            OutputStreamWriter(connection.outputStream).use {
                it.write(requestBody(target.userId, trackId, wasAlreadyLiked))
            }
            if (connection.responseCode !in 200..299) return null
            parseCount(BufferedReader(connection.inputStream.reader()).use { it.readText() })
        } catch (_: Exception) {
            null
        }
    }
}
