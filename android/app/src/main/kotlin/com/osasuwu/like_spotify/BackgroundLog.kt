package com.osasuwu.like_spotify

import android.util.Log

/**
 * Mirrors background log events to logcat.
 *
 * Every Kotlin-side producer ([SpotifyLikeWorker], [MediaButtonForegroundService],
 * [PlaybackNotificationListenerService], [YouTubeMusicLiker]) reports through
 * `LocalBroadcastManager`, and `MainActivity` is the only receiver. With the app
 * swiped out of recents that receiver is gone, so every event is discarded --
 * which made the exact scenario the background worker exists for completely
 * unobservable. Two failures have already been undiagnosable because of it.
 *
 * This is the cheap half of that fix: one extra line per event, under a single
 * tag, so `adb logcat -s LikeCurrentSong:*` shows what the background path did.
 * Carrying events across a restart so they reach the in-app Logs screen is the
 * other half, tracked separately.
 */
object BackgroundLog {

    const val TAG = "LikeCurrentSong"

    /**
     * Anything this long and this uniform is a credential, not an identifier --
     * a Spotify track or playlist id is 22 characters, a YouTube video id 11,
     * while access and refresh tokens run to the hundreds. No current call site
     * puts a token in a message; this is here so a future one cannot.
     */
    private val SECRET_RUN = Regex("[A-Za-z0-9_-]{40,}")

    /** Formatted separately from the emit so it can be tested without an Android runtime. */
    fun format(
        message: String,
        actionType: String,
        result: String,
        targetId: String? = null,
        httpCode: Int? = null,
    ): String {
        val head = "[$actionType/$result]"
        val tail = buildString {
            if (targetId != null) append(" target=$targetId")
            if (httpCode != null) append(" http=$httpCode")
        }
        return head + " " + redact(message) + tail
    }

    fun redact(message: String): String = SECRET_RUN.replace(message, "<redacted>")

    fun emit(
        message: String,
        actionType: String,
        result: String,
        targetId: String? = null,
        httpCode: Int? = null,
    ) {
        val line = format(message, actionType, result, targetId, httpCode)
        // Warn for anything the user would call a failure, info otherwise: it
        // keeps `logcat *:W` useful without having to know the tag.
        if (result == "failure" || result == "error") Log.w(TAG, line) else Log.i(TAG, line)
    }
}
