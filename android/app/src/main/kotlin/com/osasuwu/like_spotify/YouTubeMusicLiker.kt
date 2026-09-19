package com.osasuwu.like_spotify

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.media.MediaMetadata
import android.media.Rating
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import org.json.JSONObject
import java.io.BufferedReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * Likes the song playing in the YouTube Music app.
 *
 * 1. **Session like (primary).** YouTube Music's media session exposes no
 *    videoId, but it honours `setRating(thumbUp)` and reports the current
 *    thumb in `USER_RATING` (probe: #93). No sign-in, no quota, and always the
 *    exact track. `setRating` is idempotent; the `thumbs_up_action` custom
 *    action is a toggle and is deliberately never used.
 * 2. **Data API fallback.** Only when the session has no thumb rating support
 *    or the rating does not stick: `search.list` with the desktop pick order,
 *    then `videos.rate`. Needs the device-flow tokens from #94.
 *
 * Blocking (sleeps and HTTP): call [like] off the main thread. The caller
 * owns the outcome's feedback tone and final log line; this class only logs
 * the intermediate steps.
 */
class YouTubeMusicLiker(context: Context) {
    private val context = context.applicationContext
    private val prefs: SharedPreferences =
        this.context.getSharedPreferences(AppConstants.PREFS, Context.MODE_PRIVATE)

    enum class Kind { LIKED, ALREADY_LIKED, COOLDOWN, FAILED }

    data class Outcome(
        val kind: Kind,
        /** "Title — Artist" for logs; null when nothing is playing. */
        val trackName: String?,
        /** Why a like failed; null otherwise. */
        val error: String? = null,
        val httpCode: Int? = null,
    ) {
        /** Whether the user should hear the success tone. */
        val positive: Boolean get() = kind != Kind.FAILED

        /** The final log line when no Flutter UI is attached to log it. */
        fun logLine(): String {
            val name = trackName ?: "YouTube Music"
            return when (kind) {
                Kind.LIKED -> "Liked: $name"
                Kind.ALREADY_LIKED -> "Already liked: $name"
                Kind.COOLDOWN -> "Like skipped (cooldown): $name"
                Kind.FAILED -> "Like failed: ${error ?: "unknown error"}"
            }
        }

        /** Shape returned over the `likeYouTubeMusic` method channel. */
        fun toChannelMap(): Map<String, Any?> = mapOf(
            "outcome" to when (kind) {
                Kind.LIKED -> "liked"
                Kind.ALREADY_LIKED -> "already_liked"
                Kind.COOLDOWN -> "cooldown"
                Kind.FAILED -> "failed"
            },
            "trackName" to trackName,
            "message" to error,
            "httpCode" to httpCode,
        )
    }

    private data class NowPlaying(val title: String, val artist: String) {
        val display: String get() = if (artist.isBlank()) title else "$title — $artist"
    }

    fun like(): Outcome = synchronized(LOCK) { likeLocked() }

    private fun likeLocked(): Outcome {
        // Without a session there is no title/artist either, so the Data API
        // fallback has nothing to search for.
        val controller = findController()
            ?: return Outcome(Kind.FAILED, trackName = null, error = "YouTube Music is not playing")
        val nowPlaying = readNowPlaying(controller)
            ?: return Outcome(Kind.FAILED, trackName = null, error = "no song in the YouTube Music session")

        val cooldown = cooldownMinutes()
        val key = cooldownKey(nowPlaying.title, nowPlaying.artist)
        if (cooldown != null && isWithinCooldown(key, cooldown)) {
            return Outcome(Kind.COOLDOWN, nowPlaying.display)
        }

        val outcome = when (sessionLike(controller)) {
            SessionResult.ALREADY_LIKED -> Outcome(Kind.ALREADY_LIKED, nowPlaying.display)
            SessionResult.LIKED -> Outcome(Kind.LIKED, nowPlaying.display)
            SessionResult.UNSUPPORTED, SessionResult.DID_NOT_STICK -> apiLike(nowPlaying)
        }
        if (outcome.positive) recordLikedAt(key)
        return outcome
    }

    // ---- Session like -------------------------------------------------

    private enum class SessionResult { LIKED, ALREADY_LIKED, UNSUPPORTED, DID_NOT_STICK }

    /**
     * The YouTube Music controller, preferring one that is playing. Needs
     * notification access (the same grant the playback-state fallback uses).
     */
    private fun findController(): MediaController? {
        val manager = context.getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager
            ?: return null
        val component = ComponentName(context, PlaybackNotificationListenerService::class.java)
        val controllers = try {
            manager.getActiveSessions(component)
        } catch (_: SecurityException) {
            log("YouTube Music session unavailable: notification access is off", result = "failure")
            return null
        }
        val ytm = controllers.filter { MusicProvider.YTMUSIC.ownsSession(it.packageName) }
        return ytm.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
            ?: ytm.firstOrNull { it.metadata != null }
    }

    private fun readNowPlaying(controller: MediaController): NowPlaying? {
        val metadata = controller.metadata ?: return null
        val title = metadata.getString(MediaMetadata.METADATA_KEY_TITLE)?.trim().orEmpty()
        if (title.isEmpty()) return null
        val artist = YouTubeDataApi.cleanArtist(
            metadata.getString(MediaMetadata.METADATA_KEY_ARTIST)
                ?: metadata.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST)
        )
        return NowPlaying(title, artist)
    }

    private fun isThumbUp(controller: MediaController): Boolean {
        val rating = controller.metadata?.getRating(MediaMetadata.METADATA_KEY_USER_RATING) ?: return false
        return rating.ratingStyle == Rating.RATING_THUMB_UP_DOWN && rating.isRated && rating.isThumbUp
    }

    private fun sessionLike(controller: MediaController): SessionResult {
        if (controller.ratingType != Rating.RATING_THUMB_UP_DOWN) {
            log("YouTube Music session has no thumb rating (type ${controller.ratingType}); using the Data API")
            return SessionResult.UNSUPPORTED
        }
        if (isThumbUp(controller)) return SessionResult.ALREADY_LIKED

        val sent = runCatching {
            controller.transportControls.setRating(Rating.newThumbRating(true))
        }
        if (sent.isFailure) {
            log("YouTube Music session refused the rating: ${sent.exceptionOrNull()?.message}", result = "failure")
            return SessionResult.DID_NOT_STICK
        }

        // getMetadata() is a fresh binder call, so polling sees the update
        // without a callback (and without needing a Looper on this thread).
        val deadline = System.currentTimeMillis() + CONFIRM_TIMEOUT_MS
        while (System.currentTimeMillis() < deadline) {
            Thread.sleep(CONFIRM_POLL_MS)
            if (isThumbUp(controller)) return SessionResult.LIKED
        }
        log("YouTube Music did not confirm the like within ${CONFIRM_TIMEOUT_MS} ms; using the Data API")
        return SessionResult.DID_NOT_STICK
    }

    // ---- Data API fallback -------------------------------------------------

    private class ApiFailure(val outcomeError: String, val httpCode: Int?) : Exception(outcomeError)

    private fun apiLike(nowPlaying: NowPlaying): Outcome {
        val refreshToken = prefs.getString(AppConstants.KEY_YTM_REFRESH_TOKEN, null)
        val accessToken = prefs.getString(AppConstants.KEY_YTM_ACCESS_TOKEN, null)
        if (refreshToken.isNullOrBlank() && accessToken.isNullOrBlank()) {
            log("Session like unavailable — sign in to YouTube Music for the fallback", result = "failure")
            return Outcome(Kind.FAILED, nowPlaying.display, error = "sign in to YouTube Music for the fallback")
        }
        return try {
            val videoId = resolveVideoId(nowPlaying)
                ?: return Outcome(Kind.FAILED, nowPlaying.display, error = "no YouTube match for this song")
            val encoded = URLEncoder.encode(videoId, Charsets.UTF_8.name())
            apiCall("POST", "${YouTubeDataApi.API_BASE}/videos/rate?id=$encoded&rating=like")
            log("Liked via YouTube Data API: $videoId", result = "success")
            Outcome(Kind.LIKED, nowPlaying.display)
        } catch (failure: ApiFailure) {
            Outcome(Kind.FAILED, nowPlaying.display, error = failure.outcomeError, httpCode = failure.httpCode)
        } catch (e: Exception) {
            Outcome(Kind.FAILED, nowPlaying.display, error = "network error: ${e.message}")
        }
    }

    private fun resolveVideoId(nowPlaying: NowPlaying): String? {
        val cacheKey = cooldownKey(nowPlaying.title, nowPlaying.artist)
        synchronized(RESOLVED) { RESOLVED[cacheKey] }?.let { return it }

        val query = URLEncoder.encode(
            YouTubeDataApi.searchQuery(nowPlaying.artist, nowPlaying.title),
            Charsets.UTF_8.name(),
        )
        val fields = URLEncoder.encode("items(id/videoId,snippet/channelTitle)", Charsets.UTF_8.name())
        val body = apiCall(
            "GET",
            "${YouTubeDataApi.API_BASE}/search?part=snippet&type=video" +
                "&videoCategoryId=${YouTubeDataApi.MUSIC_CATEGORY_ID}" +
                "&maxResults=${YouTubeDataApi.SEARCH_MAX_RESULTS}&fields=$fields&q=$query",
        )
        val videoId = YouTubeDataApi.pickVideo(YouTubeDataApi.parseSearchCandidates(body), nowPlaying.artist)
            ?: return null
        synchronized(RESOLVED) {
            if (RESOLVED.size >= RESOLVED_CACHE_SIZE) RESOLVED.remove(RESOLVED.keys.first())
            RESOLVED[cacheKey] = videoId
        }
        return videoId
    }

    /** One Data API call with a single refresh-and-retry on 401. Returns the body. */
    private fun apiCall(method: String, url: String): String {
        var token = freshAccessToken(forceRefresh = false)
        var retried = false
        while (true) {
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.requestMethod = method
            connection.connectTimeout = HTTP_TIMEOUT_MS
            connection.readTimeout = HTTP_TIMEOUT_MS
            connection.setRequestProperty("Authorization", "Bearer $token")
            if (method == "POST") {
                // videos.rate takes everything in the query string; send an empty body.
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(0)
                connection.outputStream.close()
            }
            val status = connection.responseCode
            if (status in 200..299) return readBody(connection, error = false).orEmpty()

            val errorBody = readBody(connection, error = true)
            when (YouTubeDataApi.classifyApiError(status, errorBody)) {
                YouTubeDataApi.ErrorKind.TOKEN_EXPIRED -> {
                    if (!retried) {
                        retried = true
                        token = freshAccessToken(forceRefresh = true)
                        continue
                    }
                    notifyReauth()
                    throw ApiFailure("YouTube Music sign-in expired", status)
                }
                YouTubeDataApi.ErrorKind.RATE_LIMITED -> {
                    log(
                        "YouTube Data API rate-limited (daily quota resets at midnight Pacific time)",
                        result = "failure",
                        httpCode = status,
                    )
                    throw ApiFailure("YouTube Data API rate-limited", status)
                }
                YouTubeDataApi.ErrorKind.REAUTH_REQUIRED -> {
                    notifyReauth()
                    throw ApiFailure("YouTube refused access (${YouTubeDataApi.errorReason(errorBody) ?: "forbidden"})", status)
                }
                YouTubeDataApi.ErrorKind.TRANSIENT ->
                    throw ApiFailure("YouTube Data API unavailable", status)
                YouTubeDataApi.ErrorKind.FAILED ->
                    throw ApiFailure("YouTube Data API error ${YouTubeDataApi.errorReason(errorBody) ?: status}", status)
            }
        }
    }

    /** The stored access token, refreshed first when it is (nearly) expired or [forceRefresh]. */
    private fun freshAccessToken(forceRefresh: Boolean): String {
        val access = prefs.getString(AppConstants.KEY_YTM_ACCESS_TOKEN, null)
        val expiresAt = prefs.getLong(AppConstants.KEY_YTM_TOKEN_EXPIRES_AT, 0L)
        val stale = expiresAt > 0L && expiresAt - System.currentTimeMillis() < REFRESH_MARGIN_MS
        if (!forceRefresh && !stale && !access.isNullOrBlank()) return access
        return refreshAccessToken()
    }

    private fun refreshAccessToken(): String {
        val refreshToken = prefs.getString(AppConstants.KEY_YTM_REFRESH_TOKEN, null)
        val clientId = prefs.getString(AppConstants.KEY_YTM_CLIENT_ID, null)
        val clientSecret = prefs.getString(AppConstants.KEY_YTM_CLIENT_SECRET, null)
        if (refreshToken.isNullOrBlank() || clientId.isNullOrBlank()) {
            notifyReauth()
            throw ApiFailure("YouTube Music sign-in incomplete", null)
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
            when (YouTubeDataApi.classifyTokenError(status, body)) {
                YouTubeDataApi.ErrorKind.REAUTH_REQUIRED -> {
                    notifyReauth()
                    throw ApiFailure("YouTube Music sign-in revoked", status)
                }
                else -> throw ApiFailure("YouTube token refresh failed", status)
            }
        }

        val json = JSONObject(readBody(connection, error = false).orEmpty())
        val access = json.optString("access_token")
        if (access.isBlank()) throw ApiFailure("YouTube token refresh returned no token", status)
        val editor = prefs.edit().putString(AppConstants.KEY_YTM_ACCESS_TOKEN, access)
        json.optString("refresh_token").takeIf { it.isNotBlank() }?.let {
            editor.putString(AppConstants.KEY_YTM_REFRESH_TOKEN, it)
        }
        val expiresIn = json.optLong("expires_in", 0L)
        if (expiresIn > 0L) {
            editor.putLong(AppConstants.KEY_YTM_TOKEN_EXPIRES_AT, System.currentTimeMillis() + expiresIn * 1000L)
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

    // ---- Re-auth notification -------------------------------------------------

    private fun notifyReauth() {
        log("YouTube Music sign-in needs renewing — sign in to YouTube Music again", result = "failure")
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.getSystemService(NotificationManager::class.java)?.createNotificationChannel(
                NotificationChannel(
                    AppConstants.ACCOUNT_NOTIFICATION_CHANNEL_ID,
                    AppConstants.ACCOUNT_NOTIFICATION_CHANNEL_NAME,
                    NotificationManager.IMPORTANCE_DEFAULT,
                )
            )
        }
        val openApp = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val contentIntent = openApp?.let {
            PendingIntent.getActivity(
                context,
                REAUTH_REQUEST_CODE,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
        val notification = NotificationCompat.Builder(context, AppConstants.ACCOUNT_NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_error)
            .setContentTitle("Sign in to YouTube Music again")
            .setContentText("Likes that need the YouTube Data API can't reach your account.")
            .setAutoCancel(true)
            .setContentIntent(contentIntent)
            .build()
        // areNotificationsEnabled() covers the POST_NOTIFICATIONS grant.
        runCatching { manager.notify(AppConstants.YTM_REAUTH_NOTIFICATION_ID, notification) }
    }

    // ---- Like cooldown -------------------------------------------------

    /** Minutes of cooldown, or null when the rule is off. */
    private fun cooldownMinutes(): Int? {
        if (!prefs.getBoolean(AppConstants.KEY_RULE_LIKE_COOLDOWN_ENABLED, true)) return null
        val minutes = prefs.getInt(
            AppConstants.KEY_RULE_LIKE_COOLDOWN_MINUTES,
            AppConstants.DEFAULT_LIKE_COOLDOWN_MINUTES,
        )
        return if (minutes >= 0) minutes else AppConstants.DEFAULT_LIKE_COOLDOWN_MINUTES
    }

    private fun lastLikedMap(): JSONObject {
        val raw = prefs.getString(AppConstants.KEY_TRACK_LAST_LIKED_AT, null) ?: return JSONObject()
        return runCatching { JSONObject(raw) }.getOrDefault(JSONObject())
    }

    private fun isWithinCooldown(key: String, minutes: Int): Boolean {
        val last = lastLikedMap().optLong(key, 0L)
        return last > 0L && System.currentTimeMillis() - last < minutes * 60_000L
    }

    private fun recordLikedAt(key: String) {
        val map = lastLikedMap().put(key, System.currentTimeMillis())
        prefs.edit().putString(AppConstants.KEY_TRACK_LAST_LIKED_AT, map.toString()).apply()
    }

    // ---- Logging -------------------------------------------------

    private fun log(message: String, result: String = "info", httpCode: Int? = null) {
        val intent = Intent(AppConstants.ACTION_LOG_EVENT)
            .putExtra(AppConstants.EXTRA_LOG, message)
            .putExtra(AppConstants.EXTRA_LOG_ACTION_TYPE, "like_track")
            .putExtra(AppConstants.EXTRA_LOG_RESULT, result)
        if (httpCode != null) intent.putExtra(AppConstants.EXTRA_LOG_HTTP_CODE, httpCode)
        LocalBroadcastManager.getInstance(context).sendBroadcast(intent)
    }

    companion object {
        private const val CONFIRM_TIMEOUT_MS = 2_000L
        private const val CONFIRM_POLL_MS = 150L
        private const val HTTP_TIMEOUT_MS = 10_000
        private const val REFRESH_MARGIN_MS = 5 * 60_000L
        private const val REAUTH_REQUEST_CODE = 6
        private const val RESOLVED_CACHE_SIZE = 64

        /** Serialises likes from the service and the Flutter channel. */
        private val LOCK = Any()

        /** cooldownKey -> videoId: saves 100 quota units on a repeat fallback. */
        private val RESOLVED = LinkedHashMap<String, String>()

        /**
         * Cooldown (and search-cache) key. YouTube Music's session has no
         * videoId, so the song is identified by title + artist, case-folded.
         * The `ytmusic:` prefix keeps it apart from Spotify track ids in the
         * shared last-liked map.
         */
        fun cooldownKey(title: String, artist: String): String =
            "ytmusic:${artist.trim().lowercase()}${title.trim().lowercase()}"
    }
}
