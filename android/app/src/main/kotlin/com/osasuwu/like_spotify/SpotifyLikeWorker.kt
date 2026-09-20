package com.osasuwu.like_spotify

import android.content.Context
import android.content.SharedPreferences
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URLEncoder
import java.net.URL

/**
 * Background worker for liking the current Spotify track when the Flutter engine
 * is not attached (background media-button trigger via WorkManager).
 *
 * Mirrors the canonical rule pipeline in the Dart layer
 * ([SpotifyMusicServiceRepository.likeTrack]): like -> remove from archive playlist
 * (non-blocking) -> increment track like count (Supabase-first, local fallback) ->
 * promote to best playlist at threshold -> increment artist like count (local only) ->
 * auto-follow artist at threshold.
 */
class SpotifyLikeWorker(
    appContext: Context,
    params: WorkerParameters
) : Worker(appContext, params) {

    override fun doWork(): Result {
        // The service the trigger resolved to, carried from enqueue time: the
        // job honours the decision that was made (and logged) rather than
        // resolving again against state that has since moved on. A job queued
        // before this input existed falls back to resolving now.
        val provider = inputData.getString(KEY_ROUTED_PROVIDER)
            ?.let { id -> MusicProvider.values().firstOrNull { it.id == id } }
            ?: MusicProvider.resolve(applicationContext).provider
        // Never send a Spotify request for another service's trigger.
        if (provider != MusicProvider.SPOTIFY) {
            log("Like skipped: music service is ${provider.displayName}, not Spotify", actionType = "like_track", result = "info")
            return Result.success()
        }

        val prefs = applicationContext.getSharedPreferences(AppConstants.PREFS, Context.MODE_PRIVATE)
        var accessToken = prefs.getString(AppConstants.KEY_SPOTIFY_ACCESS_TOKEN, null)
        val refreshToken = prefs.getString(AppConstants.KEY_SPOTIFY_REFRESH_TOKEN, null)
        val clientId = prefs.getString(AppConstants.KEY_SPOTIFY_CLIENT_ID, null)

        if (accessToken.isNullOrBlank()) {
            log("Like skipped: Spotify access token missing", actionType = "like_track", result = "failure")
            playFeedbackTone(success = false)
            return Result.success()
        }

        // Proactive token refresh: if token expires within 5 minutes
        val expiresAt = prefs.getLong(AppConstants.KEY_SPOTIFY_EXPIRES_AT, 0L)
        val nowSec = System.currentTimeMillis() / 1000L
        if (expiresAt > 0 && (expiresAt - nowSec) < 300 && !refreshToken.isNullOrBlank() && !clientId.isNullOrBlank()) {
            log("Token expires in ${expiresAt - nowSec}s, refreshing...")
            val refreshed = refreshAccessToken(refreshToken, clientId)
            if (refreshed != null && refreshed.accessToken.isNotBlank()) {
                accessToken = refreshed.accessToken
                val editor = prefs.edit()
                    .putString(AppConstants.KEY_SPOTIFY_ACCESS_TOKEN, accessToken)
                if (!refreshed.refreshToken.isNullOrBlank()) {
                    editor.putString(AppConstants.KEY_SPOTIFY_REFRESH_TOKEN, refreshed.refreshToken)
                }
                if (refreshed.expiresInSec != null && refreshed.expiresInSec > 0) {
                    editor.putLong(AppConstants.KEY_SPOTIFY_EXPIRES_AT, (nowSec + refreshed.expiresInSec))
                }
                editor.apply()
            }
        }

        // Get current track
        var track = currentTrack(accessToken)
        if (track == null && !refreshToken.isNullOrBlank() && !clientId.isNullOrBlank()) {
            // 401 retry
            val refreshed = refreshAccessToken(refreshToken, clientId)
            if (refreshed != null && refreshed.accessToken.isNotBlank()) {
                accessToken = refreshed.accessToken
                prefs.edit()
                    .putString(AppConstants.KEY_SPOTIFY_ACCESS_TOKEN, accessToken)
                    .apply()
                track = currentTrack(accessToken)
            }
        }

        if (track == null) {
            log("Like skipped: no currently playing track", actionType = "like_track", result = "failure")
            playFeedbackTone(success = false)
            return Result.success()
        }

        val token = accessToken
        if (token.isNullOrBlank()) {
            playFeedbackTone(success = false)
            return Result.success()
        }

        val ruleConfig = loadRuleConfig(prefs)

        // Skip if this track was liked within the cooldown window
        if (ruleConfig.likeCooldownEnabled && isWithinCooldown(prefs, track.id, ruleConfig.likeCooldownMinutes)) {
            log(
                "Like skipped: track liked recently (cooldown)",
                actionType = "like_track",
                targetId = track.id,
                result = "info"
            )
            playFeedbackTone(success = true)
            return Result.success()
        }

        // Like the track
        val likeResult = likeTrack(track.id, token)
        playFeedbackTone(success = likeResult.success)
        if (!likeResult.success) {
            log(
                "Like failed for track: ${track.id}",
                actionType = "like_track",
                targetId = track.id,
                result = "failure",
                httpCode = likeResult.statusCode
            )
            return Result.success()
        }
        log("Liked track: ${track.id}", actionType = "like_track", targetId = track.id, result = "success", httpCode = likeResult.statusCode)
        recordLikedAt(prefs, track.id)

        runRulePipeline(prefs, token, track, ruleConfig)

        return Result.success()
    }

    private fun runRulePipeline(prefs: SharedPreferences, token: String, track: CurrentTrack, ruleConfig: RuleConfig) {
        if (ruleConfig.archiveRemoveEnabled && ruleConfig.archivePlaylistName.isNotBlank()) {
            runCatching {
                val archiveId = findPlaylistByName(prefs, ruleConfig.archivePlaylistName, token)
                if (archiveId != null) {
                    val result = removeTrackFromPlaylist(archiveId, track.uri, token)
                    if (result.success) {
                        log(
                            "Removed from archive playlist: ${ruleConfig.archivePlaylistName}",
                            actionType = "archive_remove",
                            targetId = track.id,
                            result = "success",
                            httpCode = result.statusCode
                        )
                    } else {
                        log(
                            "Archive removal failed",
                            actionType = "archive_remove",
                            targetId = track.id,
                            result = "failure",
                            httpCode = result.statusCode
                        )
                    }
                }
            }.onFailure {
                log(
                    "Archive removal failed: ${it.message}",
                    actionType = "archive_remove",
                    targetId = track.id,
                    result = "failure"
                )
            }
        }

        val trackCount = runCatching { incrementTrackLikeCount(prefs, track.id) }
            .getOrElse { incrementLocalCount(prefs, AppConstants.KEY_TRACK_LIKE_COUNTS, track.id) }
        if (ruleConfig.bestEnabled &&
            ruleConfig.bestPlaylistName.isNotBlank() &&
            trackCount == ruleConfig.bestThreshold
        ) {
            runCatching {
                val bestId = ensurePlaylist(prefs, ruleConfig.bestPlaylistName, token)
                if (bestId != null) {
                    val result = addTrackToPlaylist(bestId, track.uri, token)
                    if (result.success) {
                        log(
                            "Added to best playlist: ${ruleConfig.bestPlaylistName}",
                            actionType = "best_add",
                            targetId = track.id,
                            result = "success",
                            httpCode = result.statusCode
                        )
                    } else {
                        log(
                            "Best promotion failed",
                            actionType = "best_add",
                            targetId = track.id,
                            result = "failure",
                            httpCode = result.statusCode
                        )
                    }
                }
            }.onFailure {
                log(
                    "Best promotion failed: ${it.message}",
                    actionType = "best_add",
                    targetId = track.id,
                    result = "failure"
                )
            }
        }

        val artistId = track.artistId ?: return
        val artistCount = incrementLocalCount(prefs, AppConstants.KEY_ARTIST_LIKE_COUNTS, artistId)
        if (ruleConfig.followArtistEnabled && artistCount == ruleConfig.followArtistThreshold) {
            runCatching {
                val result = followArtist(artistId, token)
                if (result.success) {
                    log(
                        "Auto-followed artist: $artistId",
                        actionType = "follow_artist",
                        targetId = artistId,
                        result = "success",
                        httpCode = result.statusCode
                    )
                } else {
                    log(
                        "Follow artist failed",
                        actionType = "follow_artist",
                        targetId = artistId,
                        result = "failure",
                        httpCode = result.statusCode
                    )
                }
            }.onFailure {
                log(
                    "Follow artist failed: ${it.message}",
                    actionType = "follow_artist",
                    targetId = artistId,
                    result = "failure"
                )
            }
        }
    }

    // ---- Rule config -------------------------------------------------

    // The Flutter layer pushes the full config (setRuleConfig) on every app
    // start, so these fallbacks only apply before the app has ever run. They
    // match the fresh-install defaults: extra actions are opt-in, and an action
    // without a playlist name is skipped rather than guessed.
    private fun loadRuleConfig(prefs: SharedPreferences): RuleConfig {
        return RuleConfig(
            archiveRemoveEnabled = prefs.getBoolean(AppConstants.KEY_RULE_ARCHIVE_REMOVE_ENABLED, false),
            archivePlaylistName = prefs.getString(AppConstants.KEY_RULE_ARCHIVE_PLAYLIST_NAME, null)
                ?.trim().orEmpty(),
            bestEnabled = AppConstants.bestRuleEnabled(prefs),
            bestPlaylistName = AppConstants.bestRulePlaylistName(prefs),
            bestThreshold = AppConstants.bestRuleThreshold(prefs),
            followArtistEnabled = prefs.getBoolean(AppConstants.KEY_RULE_FOLLOW_ARTIST_ENABLED, false),
            followArtistThreshold = prefs.getInt(
                AppConstants.KEY_RULE_FOLLOW_ARTIST_THRESHOLD,
                AppConstants.DEFAULT_FOLLOW_ARTIST_THRESHOLD
            ).takeIf { it >= 1 } ?: AppConstants.DEFAULT_FOLLOW_ARTIST_THRESHOLD,
            likeCooldownEnabled = prefs.getBoolean(AppConstants.KEY_RULE_LIKE_COOLDOWN_ENABLED, true),
            likeCooldownMinutes = prefs.getInt(
                AppConstants.KEY_RULE_LIKE_COOLDOWN_MINUTES,
                AppConstants.DEFAULT_LIKE_COOLDOWN_MINUTES
            ).takeIf { it >= 0 } ?: AppConstants.DEFAULT_LIKE_COOLDOWN_MINUTES
        )
    }

    // ---- Like counting -------------------------------------------------

    private fun incrementTrackLikeCount(prefs: SharedPreferences, trackId: String): Int {
        LikeCounter.target(prefs, MusicProvider.SPOTIFY)?.let { target ->
            LikeCounter.increment(target, trackId)?.let { return it }
        }
        return incrementLocalCount(prefs, AppConstants.KEY_TRACK_LIKE_COUNTS, trackId)
    }

    private fun incrementLocalCount(prefs: SharedPreferences, key: String, id: String): Int {
        val map = loadCountMap(prefs, key)
        val next = map.optInt(id, 0) + 1
        map.put(id, next)
        prefs.edit().putString(key, map.toString()).apply()
        return next
    }

    private fun loadCountMap(prefs: SharedPreferences, key: String): JSONObject {
        val raw = prefs.getString(key, null) ?: return JSONObject()
        return try {
            JSONObject(raw)
        } catch (_: Exception) {
            JSONObject()
        }
    }

    // ---- Like cooldown -------------------------------------------------

    private fun isWithinCooldown(prefs: SharedPreferences, trackId: String, cooldownMinutes: Int): Boolean {
        val map = loadCountMap(prefs, AppConstants.KEY_TRACK_LAST_LIKED_AT)
        val last = map.optLong(trackId, 0L)
        if (last <= 0L) return false
        val elapsedMs = System.currentTimeMillis() - last
        return elapsedMs < cooldownMinutes * 60_000L
    }

    private fun recordLikedAt(prefs: SharedPreferences, trackId: String) {
        val map = loadCountMap(prefs, AppConstants.KEY_TRACK_LAST_LIKED_AT)
        map.put(trackId, System.currentTimeMillis())
        prefs.edit().putString(AppConstants.KEY_TRACK_LAST_LIKED_AT, map.toString()).apply()
    }

    // ---- Playlist lookup / creation -------------------------------------------------

    private fun findPlaylistByName(prefs: SharedPreferences, name: String, token: String): String? {
        val cache = loadPlaylistCache(prefs)
        cache.keys().forEach { key ->
            if (key.equals(name, ignoreCase = true)) {
                cache.optString(key).takeIf { it.isNotBlank() }?.let { return it }
            }
        }

        val limit = 50
        var offset = 0
        while (true) {
            val connection = api("https://api.spotify.com/v1/me/playlists?limit=$limit&offset=$offset", token, "GET")
            if (connection.responseCode !in 200..299) break
            val payload = readBody(connection) ?: break
            val json = JSONObject(payload)
            val items = json.optJSONArray("items") ?: break

            var found: String? = null
            for (i in 0 until items.length()) {
                val playlist = items.optJSONObject(i) ?: continue
                val playlistName = playlist.optString("name")
                val playlistId = playlist.optString("id")
                if (playlistName.isBlank() || playlistId.isBlank()) continue
                cache.put(playlistName, playlistId)
                if (found == null && playlistName.equals(name, ignoreCase = true)) found = playlistId
            }
            savePlaylistCache(prefs, cache)
            if (found != null) return found

            val total = json.optInt("total", items.length())
            offset += limit
            if (items.length() < limit || offset >= total) break
        }
        return null
    }

    private fun ensurePlaylist(prefs: SharedPreferences, name: String, token: String): String? {
        findPlaylistByName(prefs, name, token)?.let { return it }

        val userId = getCurrentUserId(prefs, token) ?: return null
        val body = JSONObject()
            .put("name", name)
            .put("public", false)
            .put("description", "Managed by Like Current Song")
            .toString()

        // Invalidate the cache before creating so a concurrent rebuild can't miss the new playlist.
        savePlaylistCache(prefs, JSONObject())

        val connection = apiWithBody("https://api.spotify.com/v1/users/$userId/playlists", token, "POST", body)
        if (connection.responseCode !in 200..299) return null
        val payload = readBody(connection) ?: return null
        val id = JSONObject(payload).optString("id").takeIf { it.isNotBlank() } ?: return null

        val cache = loadPlaylistCache(prefs)
        cache.put(name, id)
        savePlaylistCache(prefs, cache)
        return id
    }

    private fun loadPlaylistCache(prefs: SharedPreferences): JSONObject {
        val timestamp = prefs.getLong(AppConstants.KEY_PLAYLIST_CACHE_TIMESTAMP, 0L)
        if (System.currentTimeMillis() - timestamp > AppConstants.PLAYLIST_CACHE_TTL_MS) return JSONObject()
        val raw = prefs.getString(AppConstants.KEY_PLAYLIST_CACHE, null) ?: return JSONObject()
        return try {
            JSONObject(raw)
        } catch (_: Exception) {
            JSONObject()
        }
    }

    private fun savePlaylistCache(prefs: SharedPreferences, cache: JSONObject) {
        prefs.edit()
            .putString(AppConstants.KEY_PLAYLIST_CACHE, cache.toString())
            .putLong(AppConstants.KEY_PLAYLIST_CACHE_TIMESTAMP, System.currentTimeMillis())
            .apply()
    }

    private fun getCurrentUserId(prefs: SharedPreferences, token: String): String? {
        prefs.getString(AppConstants.KEY_SPOTIFY_USER_ID, null)?.takeIf { it.isNotBlank() }?.let { return it }
        val connection = api("https://api.spotify.com/v1/me", token, "GET")
        if (connection.responseCode !in 200..299) return null
        val payload = readBody(connection) ?: return null
        val id = JSONObject(payload).optString("id").takeIf { it.isNotBlank() } ?: return null
        prefs.edit().putString(AppConstants.KEY_SPOTIFY_USER_ID, id).apply()
        return id
    }

    private fun addTrackToPlaylist(playlistId: String, trackUri: String, token: String): ApiResult {
        val body = JSONObject().put("uris", JSONArray().put(trackUri)).toString()
        val connection = apiWithBody("https://api.spotify.com/v1/playlists/$playlistId/tracks", token, "POST", body)
        val code = connection.responseCode
        return ApiResult(code in 200..299, code)
    }

    private fun removeTrackFromPlaylist(playlistId: String, trackUri: String, token: String): ApiResult {
        val track = JSONObject().put("uri", trackUri)
        val body = JSONObject().put("tracks", JSONArray().put(track)).toString()
        val connection = apiWithBody("https://api.spotify.com/v1/playlists/$playlistId/tracks", token, "DELETE", body)
        val code = connection.responseCode
        return ApiResult(code in 200..299, code)
    }

    private fun followArtist(artistId: String, token: String): ApiResult {
        return saveToLibrary(SpotifyLibraryEndpoints.artistUri(artistId), token) {
            val encoded = URLEncoder.encode(artistId, Charsets.UTF_8.name())
            api("https://api.spotify.com/v1/me/following?type=artist&ids=$encoded", token, "PUT").responseCode
        }
    }

    /**
     * Saves/follows [uri] through the generic `PUT /me/library` endpoint,
     * running [legacy] once when that endpoint is not available to this client
     * ID (see [SpotifyLibraryEndpoints.shouldTryLegacy]). A successful legacy
     * call is remembered for the process lifetime, so only the first write of a
     * session pays two round trips.
     */
    private fun saveToLibrary(uri: String, token: String, legacy: () -> Int): ApiResult {
        if (!SpotifyLibraryEndpoints.useLegacyEndpoints) {
            val body = JSONObject().put("uris", JSONArray().put(uri)).toString()
            val code = apiWithBody(SpotifyLibraryEndpoints.LIBRARY_URL, token, "PUT", body).responseCode
            if (code in 200..299) return ApiResult(true, code)
            if (!SpotifyLibraryEndpoints.shouldTryLegacy(code)) return ApiResult(false, code)
        }

        val legacyCode = legacy()
        val ok = legacyCode in 200..299
        if (ok) SpotifyLibraryEndpoints.rememberLegacyEndpoints()
        return ApiResult(ok, legacyCode)
    }

    // ---- Core like + track lookup -------------------------------------------------

    private fun currentTrack(token: String?): CurrentTrack? {
        if (token.isNullOrBlank()) return null
        val connection = api("https://api.spotify.com/v1/me/player/currently-playing", token, "GET")
        val code = connection.responseCode
        if (code == 204 || code !in 200..299) return null
        val payload = readBody(connection) ?: return null
        val item = JSONObject(payload).optJSONObject("item") ?: return null
        val id = item.optString("id")
        if (id.isBlank()) return null
        val uri = item.optString("uri").ifBlank { "spotify:track:$id" }
        val artistId = item.optJSONArray("artists")?.optJSONObject(0)?.optString("id")?.takeIf { it.isNotBlank() }
        return CurrentTrack(id = id, uri = uri, artistId = artistId)
    }

    private fun likeTrack(trackId: String, token: String?): ApiResult {
        if (token.isNullOrBlank()) return ApiResult(false, 0)
        return saveToLibrary(SpotifyLibraryEndpoints.trackUri(trackId), token) {
            val encodedTrackId = URLEncoder.encode(trackId, Charsets.UTF_8.name())
            api("https://api.spotify.com/v1/me/tracks?ids=$encodedTrackId", token, "PUT").responseCode
        }
    }

    private fun refreshAccessToken(refreshToken: String, clientId: String): RefreshedToken? {
        val connection = URL("https://accounts.spotify.com/api/token").openConnection() as HttpURLConnection
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")

        val body = buildString {
            append("grant_type=refresh_token")
            append("&refresh_token=")
            append(URLEncoder.encode(refreshToken, Charsets.UTF_8.name()))
            append("&client_id=")
            append(URLEncoder.encode(clientId, Charsets.UTF_8.name()))
        }
        OutputStreamWriter(connection.outputStream).use { it.write(body) }

        val statusCode = connection.responseCode
        if (statusCode !in 200..299) return null
        val payload = readBody(connection) ?: return null
        val json = JSONObject(payload)
        val access = json.optString("access_token")
        if (access.isBlank()) return null
        return RefreshedToken(
            accessToken = access,
            refreshToken = json.optString("refresh_token").ifBlank { null },
            expiresInSec = if (json.has("expires_in")) json.optLong("expires_in", 0L).takeIf { it > 0L } else null
        )
    }

    // ---- HTTP plumbing -------------------------------------------------

    private fun api(url: String, token: String, method: String): HttpURLConnection {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.requestMethod = method
        connection.setRequestProperty("Authorization", "Bearer $token")
        connection.connectTimeout = 10000
        connection.readTimeout = 10000
        if (method == "PUT") connection.doOutput = true
        return connection
    }

    private fun apiWithBody(url: String, token: String, method: String, body: String): HttpURLConnection {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.requestMethod = method
        connection.setRequestProperty("Authorization", "Bearer $token")
        connection.setRequestProperty("Content-Type", "application/json")
        connection.connectTimeout = 10000
        connection.readTimeout = 10000
        connection.doOutput = true
        OutputStreamWriter(connection.outputStream).use { it.write(body) }
        return connection
    }

    private fun readBody(connection: HttpURLConnection): String? {
        return try {
            BufferedReader(connection.inputStream.reader()).use { it.readText() }
        } catch (_: Exception) {
            null
        }
    }

    private fun playFeedbackTone(success: Boolean) {
        FeedbackPlayer.play(applicationContext, success)
    }

    private fun log(
        message: String,
        actionType: String = "native",
        targetId: String? = null,
        result: String = "info",
        httpCode: Int? = null
    ) {
        val intent = android.content.Intent(AppConstants.ACTION_LOG_EVENT)
            .putExtra(AppConstants.EXTRA_LOG, message)
            .putExtra(AppConstants.EXTRA_LOG_ACTION_TYPE, actionType)
            .putExtra(AppConstants.EXTRA_LOG_RESULT, result)
        if (targetId != null) intent.putExtra(AppConstants.EXTRA_LOG_TARGET_ID, targetId)
        if (httpCode != null) intent.putExtra(AppConstants.EXTRA_LOG_HTTP_CODE, httpCode)
        androidx.localbroadcastmanager.content.LocalBroadcastManager
            .getInstance(applicationContext)
            .sendBroadcast(intent)
    }

    private data class ApiResult(val success: Boolean, val statusCode: Int)

    private data class CurrentTrack(
        val id: String,
        val uri: String,
        val artistId: String?
    )

    private data class RuleConfig(
        val archiveRemoveEnabled: Boolean,
        val archivePlaylistName: String,
        val bestEnabled: Boolean,
        val bestPlaylistName: String,
        val bestThreshold: Int,
        val followArtistEnabled: Boolean,
        val followArtistThreshold: Int,
        val likeCooldownEnabled: Boolean,
        val likeCooldownMinutes: Int
    )

    data class RefreshedToken(
        val accessToken: String,
        val refreshToken: String?,
        val expiresInSec: Long?
    )

    companion object {
        /** Id of the [MusicProvider] the trigger routed to; see [doWork]. */
        private const val KEY_ROUTED_PROVIDER = "routed_provider"

        fun enqueue(context: Context, provider: MusicProvider) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            val request = OneTimeWorkRequestBuilder<SpotifyLikeWorker>()
                .setConstraints(constraints)
                .setInputData(workDataOf(KEY_ROUTED_PROVIDER to provider.id))
                .build()

            WorkManager.getInstance(context).enqueueUniqueWork(
                "spotify-like-work",
                ExistingWorkPolicy.REPLACE,
                request
            )
        }
    }
}
