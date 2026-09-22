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
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * A Data API call that came back non-2xx, already turned into something the
 * user can read. [reason] is Google's own `error.errors[0].reason`, which some
 * callers act on (`subscriptionDuplicate`).
 */
class ApiFailure(
    val outcomeError: String,
    val httpCode: Int?,
    val reason: String? = null,
) : Exception(outcomeError)

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
 * After a like goes through, [count] adds it to the shared counter sheet
 * under the Google account's `sub`, the key desktop YouTube Music uses (#96),
 * and [extraActions] runs the opt-in playlist and follow rules (#98).
 *
 * Blocking (sleeps and HTTP): call [like], [count] and [extraActions] off the
 * main thread. The caller owns the outcome's feedback tone and final log line;
 * this class only logs the intermediate steps.
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
        /** The song the outcome is about; null when nothing is playing. */
        val nowPlaying: NowPlaying? = null,
        /** The shared counter's new value; null when the like was not counted. */
        val likeCount: Int? = null,
        /**
         * Which legs of the like went through. With the `both` destination a
         * like can half succeed, so [kind] says whether the like counted at
         * all and these say what actually happened; see [LikeDestination].
         */
        val likedNatively: Boolean = false,
        val addedToLikePlaylist: Boolean = false,
        /**
         * The leg that failed while the other one carried the like, phrased
         * for a log line. Null when nothing failed.
         */
        val partialFailure: String? = null,
    ) {
        /** Whether the user should hear the success tone. */
        val positive: Boolean get() = kind != Kind.FAILED

        /** The final log line when no Flutter UI is attached to log it. */
        fun logLine(): String {
            val name = trackName ?: "YouTube Music"
            val line = when (kind) {
                // "(xN)" matches the Dart log line (AppController._likedMessage).
                Kind.LIKED -> if (likeCount != null) "Liked: $name (x$likeCount)" else "Liked: $name"
                Kind.ALREADY_LIKED -> "Already liked: $name"
                Kind.COOLDOWN -> "Like skipped (cooldown): $name"
                Kind.FAILED -> "Like failed: ${error ?: "unknown error"}"
            }
            // Detached, this is the only line the user gets, so the half of a
            // "both" like that did not go through has to ride along with it.
            return if (partialFailure != null) "$line — $partialFailure" else line
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
            "likeCount" to likeCount,
            "likedNatively" to likedNatively,
            "addedToLikePlaylist" to addedToLikePlaylist,
            "partialFailure" to partialFailure,
        )
    }

    /**
     * What one run of the like playlist leg did. Public, like [combine], so
     * the JUnit test can drive the destination branching.
     */
    data class PlaylistLeg(val added: Boolean, val error: String? = null, val httpCode: Int? = null)

    /** Title and (cleaned) artist read from the YouTube Music session. */
    data class NowPlaying(val title: String, val artist: String) {
        val display: String get() = if (artist.isBlank()) title else "$title — $artist"
    }

    fun like(): Outcome = synchronized(LOCK) { likeLocked() }

    /**
     * Adds a successful like to the shared counter and returns [outcome] with
     * the new [Outcome.likeCount]. Only when the user is signed in to YouTube
     * Music (the `sub` is known) and the counter sheet is set up; otherwise, or
     * when the like did not go through, [outcome] comes back unchanged.
     *
     * Never flips the outcome: a counter failure is logged and the like still
     * counts as a success.
     */
    fun count(outcome: Outcome): Outcome = synchronized(LOCK) { countLocked(outcome) }

    /**
     * Runs the user's extra like actions — archive removal, best promotion,
     * artist auto-follow — for a like that went through. Pass the outcome
     * [count] returned, so the best threshold reads the shared count
     * instead of a second one.
     *
     * All three are off by default and each costs Data API quota, so nothing
     * here touches the network unless the user turned an action on. Failures
     * are logged, never rethrown: the like itself already happened.
     */
    fun extraActions(outcome: Outcome) = synchronized(LOCK) { extraActionsLocked(outcome) }

    private fun extraActionsLocked(outcome: Outcome) {
        val nowPlaying = outcome.nowPlaying ?: return
        if (outcome.kind != Kind.LIKED && outcome.kind != Kind.ALREADY_LIKED) return

        val actions = extraActionRunner()
        if (!actions.anyEnabled()) return

        val match = try {
            resolveMatch(nowPlaying)
        } catch (failure: ApiFailure) {
            log("Extra actions skipped: ${failure.outcomeError}", httpCode = failure.httpCode, actionType = EXTRAS_ACTION)
            return
        } catch (e: Exception) {
            log("Extra actions skipped: network error: ${e.message}", actionType = EXTRAS_ACTION)
            return
        }
        if (match == null) {
            log("Extra actions skipped: no YouTube match for this song", actionType = EXTRAS_ACTION)
            return
        }
        actions.run(match, outcome.likeCount)
    }

    /**
     * A runner bound to this liker's API call and log. Cheap to build — it
     * only reads the rules out of prefs — so both the like's playlist leg and
     * the extra actions make their own.
     */
    private fun extraActionRunner() = YouTubeMusicExtraActions(
        prefs,
        apiCall = ::apiCall,
        log = { message, actionType, result, httpCode ->
            log(message, result = result, httpCode = httpCode, actionType = actionType)
        },
    )

    private fun countLocked(outcome: Outcome): Outcome {
        val nowPlaying = outcome.nowPlaying ?: return outcome
        if (outcome.kind != Kind.LIKED && outcome.kind != Kind.ALREADY_LIKED) return outcome
        val target = LikeCounter.target(prefs, MusicProvider.YTMUSIC) ?: return outcome

        val videoId = try {
            resolveMatch(nowPlaying)?.videoId
        } catch (failure: ApiFailure) {
            log("Like not counted: ${failure.outcomeError}", actionType = COUNT_ACTION, httpCode = failure.httpCode)
            return outcome
        } catch (e: Exception) {
            log("Like not counted: network error: ${e.message}", actionType = COUNT_ACTION)
            return outcome
        }
        if (videoId == null) {
            log("Like not counted: no YouTube match for this song", actionType = COUNT_ACTION)
            return outcome
        }
        val newCount = LikeCounter.increment(
            prefs,
            target,
            trackId = videoId,
            wasAlreadyLiked = outcome.kind == Kind.ALREADY_LIKED,
        )
        if (newCount == null) {
            log("Like not counted: the shared counter did not answer", actionType = COUNT_ACTION)
            return outcome
        }
        return outcome.copy(likeCount = newCount)
    }

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
            return Outcome(Kind.COOLDOWN, nowPlaying.display, nowPlaying = nowPlaying)
        }

        // Where the user wants likes to go. The native leg runs first: it is
        // the cheap one (no search, no quota) and the one they see in the
        // YouTube Music app.
        val destination = AppConstants.likeRuleDestination(prefs)
        val playlistName = AppConstants.likeRulePlaylistName(prefs)
        val native = if (destination.likesNatively) nativeLike(controller, nowPlaying) else null
        val playlist = if (destination.addsToPlaylist) addToLikePlaylist(nowPlaying, playlistName) else null

        val outcome = combine(destination, nowPlaying, playlistName, native, playlist)
        if (outcome.positive) recordLikedAt(key)
        return outcome
    }

    /** The service's own like: the media session, falling back to the Data API. */
    private fun nativeLike(controller: MediaController, nowPlaying: NowPlaying): Outcome =
        when (sessionLike(controller)) {
            SessionResult.ALREADY_LIKED -> Outcome(Kind.ALREADY_LIKED, nowPlaying.display)
            SessionResult.LIKED -> Outcome(Kind.LIKED, nowPlaying.display)
            SessionResult.UNSUPPORTED, SessionResult.DID_NOT_STICK -> apiLike(nowPlaying)
        }

    /**
     * Adds the song to the user's like playlist, creating it the first time.
     *
     * Costs a `playlistItems.insert` (50 units) per like, plus the search the
     * song's videoId needs — cached per song, so a repeat like is one write.
     * The result is reported by the caller, not logged here: the leg is part
     * of the like, so it belongs in the like's own line.
     */
    private fun addToLikePlaylist(nowPlaying: NowPlaying, playlistName: String): PlaylistLeg = try {
        val match = resolveMatch(nowPlaying)
        if (match == null) {
            PlaylistLeg(false, "no YouTube match for this song")
        } else {
            val added = extraActionRunner().addToPlaylist(
                playlistName,
                match.videoId,
                YouTubeMusicExtraActions.LIKE_PLAYLIST_ACTION,
                what = null,
            )
            if (added) PlaylistLeg(true) else PlaylistLeg(false, "could not find or create \"$playlistName\"")
        }
    } catch (failure: ApiFailure) {
        PlaylistLeg(false, failure.outcomeError, failure.httpCode)
    } catch (e: Exception) {
        PlaylistLeg(false, "network error: ${e.message}")
    }

    // ---- Session like -------------------------------------------------

    private enum class SessionResult { LIKED, ALREADY_LIKED, UNSUPPORTED, DID_NOT_STICK }

    /**
     * The YouTube Music controller, preferring one that is playing. Needs
     * notification access — the same grant the trigger itself runs on.
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

    private fun apiLike(nowPlaying: NowPlaying): Outcome {
        val refreshToken = prefs.getString(AppConstants.KEY_YTM_REFRESH_TOKEN, null)
        val accessToken = prefs.getString(AppConstants.KEY_YTM_ACCESS_TOKEN, null)
        if (refreshToken.isNullOrBlank() && accessToken.isNullOrBlank()) {
            log("Session like unavailable — sign in to YouTube Music for the fallback", result = "failure")
            return Outcome(Kind.FAILED, nowPlaying.display, error = "sign in to YouTube Music for the fallback")
        }
        return try {
            val videoId = resolveMatch(nowPlaying)?.videoId
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

    private fun resolveMatch(nowPlaying: NowPlaying): YouTubeDataApi.Match? {
        val cacheKey = cooldownKey(nowPlaying.title, nowPlaying.artist)
        synchronized(RESOLVED) { RESOLVED[cacheKey] }?.let { return it }

        val query = URLEncoder.encode(
            YouTubeDataApi.searchQuery(nowPlaying.artist, nowPlaying.title),
            Charsets.UTF_8.name(),
        )
        val fields = URLEncoder.encode(
            "items(id/videoId,snippet/channelTitle,snippet/channelId)",
            Charsets.UTF_8.name(),
        )
        val body = apiCall(
            "GET",
            "${YouTubeDataApi.API_BASE}/search?part=snippet&type=video" +
                "&videoCategoryId=${YouTubeDataApi.MUSIC_CATEGORY_ID}" +
                "&maxResults=${YouTubeDataApi.SEARCH_MAX_RESULTS}&fields=$fields&q=$query",
        )
        val match = YouTubeDataApi.pickMatch(YouTubeDataApi.parseSearchCandidates(body), nowPlaying.artist)
            ?: return null
        synchronized(RESOLVED) {
            if (RESOLVED.size >= RESOLVED_CACHE_SIZE) RESOLVED.remove(RESOLVED.keys.first())
            RESOLVED[cacheKey] = match
        }
        return match
    }

    /** One Data API call with a single refresh-and-retry on 401. Returns the body. */
    private fun apiCall(method: String, url: String, body: String? = null): String {
        var token = freshAccessToken(forceRefresh = false)
        var retried = false
        while (true) {
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.requestMethod = method
            connection.connectTimeout = HTTP_TIMEOUT_MS
            connection.readTimeout = HTTP_TIMEOUT_MS
            connection.setRequestProperty("Authorization", "Bearer $token")
            if (method == "POST") {
                connection.doOutput = true
                if (body == null) {
                    // videos.rate takes everything in the query string; send an empty body.
                    connection.setFixedLengthStreamingMode(0)
                    connection.outputStream.close()
                } else {
                    val payload = body.toByteArray(Charsets.UTF_8)
                    connection.setRequestProperty("Content-Type", "application/json")
                    connection.setFixedLengthStreamingMode(payload.size)
                    connection.outputStream.use { it.write(payload) }
                }
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
                YouTubeDataApi.ErrorKind.FAILED -> {
                    val reason = YouTubeDataApi.errorReason(errorBody)
                    throw ApiFailure("YouTube Data API error ${reason ?: status}", status, reason)
                }
            }
        }
    }

    /**
     * The stored access token, refreshed first when it is (nearly) expired or
     * [forceRefresh]. The exchange itself is [GoogleTokens], shared with the
     * like counter's sign-in; this only turns its failures into the
     * YouTube-flavoured ones the rest of the class handles.
     */
    private fun freshAccessToken(forceRefresh: Boolean): String = try {
        GoogleTokens.fresh(prefs, GoogleTokens.YTMUSIC, forceRefresh)
    } catch (failure: GoogleTokens.RefreshFailure) {
        if (failure.needsReauth) {
            notifyReauth()
            throw ApiFailure(
                if (failure.httpCode == null) {
                    "YouTube Music sign-in incomplete"
                } else {
                    "YouTube Music sign-in revoked"
                },
                failure.httpCode,
            )
        }
        throw ApiFailure("YouTube token refresh failed", failure.httpCode)
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

    private fun log(
        message: String,
        result: String = "info",
        httpCode: Int? = null,
        actionType: String = "like_track",
    ) {
        BackgroundLog.emit(message, actionType, result, httpCode = httpCode)
        val intent = Intent(AppConstants.ACTION_LOG_EVENT)
            .putExtra(AppConstants.EXTRA_LOG, message)
            .putExtra(AppConstants.EXTRA_LOG_ACTION_TYPE, actionType)
            .putExtra(AppConstants.EXTRA_LOG_RESULT, result)
        if (httpCode != null) intent.putExtra(AppConstants.EXTRA_LOG_HTTP_CODE, httpCode)
        LocalBroadcastManager.getInstance(context).sendBroadcast(intent)
    }

    companion object {
        private const val CONFIRM_TIMEOUT_MS = 2_000L
        private const val CONFIRM_POLL_MS = 150L
        private const val HTTP_TIMEOUT_MS = 10_000
        private const val REAUTH_REQUEST_CODE = 6
        private const val RESOLVED_CACHE_SIZE = 64

        /**
         * The one outcome of the legs that ran. A one-leg destination is exactly
         * its leg; `both` only fails when both legs do, and then reports the
         * native failure, which is the one the user can act on.
         */
        fun combine(
            destination: LikeDestination,
            nowPlaying: NowPlaying,
            playlistName: String,
            native: Outcome?,
            playlist: PlaylistLeg?,
        ): Outcome {
            val nativeOk = native?.positive == true
            val playlistOk = playlist?.added == true
            if (!LikeDestination.succeeded(destination, nativeOk, playlistOk)) {
                return Outcome(
                    Kind.FAILED,
                    nowPlaying.display,
                    error = native?.error ?: playlist?.error,
                    httpCode = native?.httpCode ?: playlist?.httpCode,
                    nowPlaying = nowPlaying,
                )
            }
            val partialFailure = when {
                native != null && !nativeOk ->
                    "Liked songs failed, so the like only reached \"$playlistName\": " +
                        (native.error ?: "unknown error")
                playlist != null && !playlistOk ->
                    "Adding to \"$playlistName\" failed, so the like only reached liked songs: " +
                        (playlist.error ?: "unknown error")
                else -> null
            }
            return Outcome(
                // Nothing changed only when the service already had the song liked
                // and no playlist add came with it.
                kind = if (native?.kind == Kind.ALREADY_LIKED && !playlistOk) Kind.ALREADY_LIKED else Kind.LIKED,
                trackName = nowPlaying.display,
                nowPlaying = nowPlaying,
                likedNatively = nativeOk,
                addedToLikePlaylist = playlistOk,
                partialFailure = partialFailure,
            )
        }

        /** Log action type for the shared-counter step. */
        private const val COUNT_ACTION = "like_count"

        /** Log action type for extras that never got as far as a single action. */
        private const val EXTRAS_ACTION = "extra_actions"

        /** Serialises likes from the service and the Flutter channel. */
        private val LOCK = Any()

        /**
         * Separator between the artist and title halves of [cooldownKey].
         * Written as an escape on purpose: a literal U+001F here is
         * invisible, and reads as a missing delimiter.
         */
        private const val SEP = "\u001F"

        /** cooldownKey -> search match: saves 100 quota units on a repeat fallback, count or extra action. */
        private val RESOLVED = LinkedHashMap<String, YouTubeDataApi.Match>()

        /**
         * Cooldown (and search-cache) key. YouTube Music's session has no
         * videoId, so the song is identified by title + artist, case-folded.
         * The `ytmusic:` prefix keeps it apart from Spotify track ids in the
         * shared last-liked map.
         *
         * The two halves are joined by [SEP] (U+001F), which no session
         * metadata carries. Without it `ab`+`c` and `a`+`bc` fold onto one
         * key, and since the key also picks the cached videoId, a collision
         * would rate the wrong video.
         */
        fun cooldownKey(title: String, artist: String): String =
            "ytmusic:${artist.trim().lowercase()}$SEP${title.trim().lowercase()}"
    }
}
