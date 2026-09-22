package com.osasuwu.like_spotify

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/**
 * Carries background log events to logcat and, when nobody is listening, to
 * disk.
 *
 * Every Kotlin-side producer ([SpotifyLikeWorker], [MediaButtonForegroundService],
 * [PlaybackNotificationListenerService], [YouTubeMusicLiker]) reports through
 * `LocalBroadcastManager`, and `MainActivity` is the only receiver. With the app
 * swiped out of recents that receiver is gone, so every event is discarded --
 * which made the exact scenario the background worker exists for completely
 * unobservable. Two failures have already been undiagnosable because of it.
 *
 * Two things happen per event. One line goes to logcat under a single tag, so
 * `adb logcat -s LikeCurrentSong:*` shows what the background path did. And if
 * no Flutter engine is attached -- meaning the event has no live Logs screen to
 * reach -- the event is appended to a bounded buffer in [AppConstants.PREFS],
 * which Dart drains at startup. The attachment check is what keeps an event
 * from being recorded twice: with the app open it already arrives over the
 * event channel, so nothing is written.
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
        context: Context?,
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

        if (context == null || MainActivity.isFlutterAttached) return
        // Nothing here is worth crashing a like over.
        runCatching {
            persist(context, encodeEntry(System.currentTimeMillis(), message, actionType, result, targetId, httpCode))
        }
    }

    // ---- The buffer ----------------------------------------------
    //
    // Split the same way as format/emit: the JSON shaping is pure and tested,
    // the SharedPreferences shell around it is not.

    /** Keys match the map Dart reads in `drainBackgroundLogs`. */
    fun encodeEntry(
        atMs: Long,
        message: String,
        actionType: String,
        result: String,
        targetId: String? = null,
        httpCode: Int? = null,
    ): JSONObject = JSONObject()
        .put("atMs", atMs)
        .put("actionType", actionType)
        .put("result", result)
        .put("message", redact(message))
        .apply {
            if (targetId != null) put("targetId", targetId)
            if (httpCode != null) put("httpCode", httpCode)
        }

    /**
     * Appends [entry] to the stored array, oldest first, dropping from the
     * front until at most [max] remain. A buffer that cannot be parsed --
     * truncated by a kill mid-write, or written by a version that shaped it
     * differently -- is treated as empty rather than losing the new event.
     */
    fun appendBounded(existing: String?, entry: JSONObject, max: Int): JSONArray {
        val parsed = runCatching { JSONArray(existing ?: "[]") }.getOrDefault(JSONArray())
        val kept = JSONArray()
        // Keep the newest (max - 1), so the append lands inside the bound.
        val first = maxOf(0, parsed.length() - (max - 1))
        for (i in first until parsed.length()) {
            parsed.optJSONObject(i)?.let { kept.put(it) }
        }
        kept.put(entry)
        return kept
    }

    /** Stored entries oldest first; anything unreadable degrades to empty. */
    fun decodeEntries(raw: String?): List<Map<String, Any>> {
        val parsed = runCatching { JSONArray(raw ?: "[]") }.getOrDefault(JSONArray())
        val out = ArrayList<Map<String, Any>>(parsed.length())
        for (i in 0 until parsed.length()) {
            val entry = parsed.optJSONObject(i) ?: continue
            val map = HashMap<String, Any>(6)
            map["atMs"] = entry.optLong("atMs", 0L)
            map["actionType"] = entry.optString("actionType", "legacy")
            map["result"] = entry.optString("result", "info")
            map["message"] = entry.optString("message", "")
            entry.optString("targetId", "").takeIf { it.isNotEmpty() }?.let { map["targetId"] = it }
            if (entry.has("httpCode")) map["httpCode"] = entry.optInt("httpCode")
            out.add(map)
        }
        return out
    }

    @Synchronized
    private fun persist(context: Context, entry: JSONObject) {
        val prefs = context.applicationContext
            .getSharedPreferences(AppConstants.PREFS, Context.MODE_PRIVATE)
        val next = appendBounded(
            prefs.getString(AppConstants.KEY_BACKGROUND_LOG, null),
            entry,
            AppConstants.BACKGROUND_LOG_MAX_ENTRIES,
        )
        prefs.edit().putString(AppConstants.KEY_BACKGROUND_LOG, next.toString()).apply()
    }

    /**
     * Hands the buffered events to the caller and clears it, oldest first.
     *
     * Read-and-clear in one locked step, so an event produced while Dart is
     * draining is either handed over or kept -- never dropped between the two.
     */
    @Synchronized
    fun drain(context: Context): List<Map<String, Any>> {
        val prefs = context.applicationContext
            .getSharedPreferences(AppConstants.PREFS, Context.MODE_PRIVATE)
        val raw = prefs.getString(AppConstants.KEY_BACKGROUND_LOG, null) ?: return emptyList()
        prefs.edit().remove(AppConstants.KEY_BACKGROUND_LOG).commit()
        return decodeEntries(raw)
    }
}
