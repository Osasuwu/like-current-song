package com.osasuwu.like_spotify

import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * The cross-device like counter: a Google Sheet the user owns, shared with the
 * Dart layer (`lib/data/likes/google_sheets_like_count_repository.dart`) and
 * the desktop app (`like_spotify/extensions/google_sheets_storage`). Keep the
 * three in step.
 *
 * The sheet has a tab named [SHEET] whose first row is the header
 * `user_id | track_id | count | backfilled | updated_at`. A row is keyed by
 * (user id, track id), where both ids come from the music service the like
 * went through, so the phone and the computer add to the same count per
 * account.
 */
object LikeCounter {
    private const val HTTP_TIMEOUT_MS = 5_000
    private const val API_BASE = "https://sheets.googleapis.com/v4/spreadsheets"

    /** The tab the counts live on. */
    const val SHEET = "Likes"

    /** Where one like is counted. The access token is fetched per call. */
    data class Target(val spreadsheetId: String, val userId: String)

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

    /**
     * The counter target for [provider], or null when no spreadsheet is
     * configured or there is no user id.
     */
    fun target(prefs: SharedPreferences, provider: MusicProvider): Target? {
        val spreadsheetId = prefs.getString(AppConstants.KEY_COUNTER_SPREADSHEET_ID, null)?.trim()
        if (spreadsheetId.isNullOrEmpty()) return null
        val userId = userIdFor(
            provider,
            spotifyUserId = prefs.getString(AppConstants.KEY_SPOTIFY_USER_ID, null),
            ytmUserSub = prefs.getString(AppConstants.KEY_YTM_USER_SUB, null),
        ) ?: return null
        return Target(spreadsheetId, userId)
    }

    /** The row a value update landed on, read out of `updatedRange`. */
    fun rowFromA1Range(range: String?): Int? {
        if (range.isNullOrBlank()) return null
        return Regex("\\d+").findAll(range).lastOrNull()?.value?.toIntOrNull()
    }

    /**
     * The row index of (user id, track id) in a `values.get` body, and the
     * count currently on it. Row 1 is the header, so data starts at row 2.
     * Null when the pair has no row yet.
     */
    fun findRow(body: String?, userId: String, trackId: String): Pair<Int, Int>? {
        val values = runCatching { JSONObject(body.orEmpty()).optJSONArray("values") }.getOrNull()
            ?: return null
        for (offset in 1 until values.length()) {
            val row = values.optJSONArray(offset) ?: continue
            if (row.optString(0) != userId || row.optString(1) != trackId) continue
            return (offset + 1) to (row.optString(2).trim().toIntOrNull() ?: 0)
        }
        return null
    }

    /** A timestamp in the same shape the desktop writes: `%Y-%m-%dT%H:%M:%SZ`. */
    fun nowIso(): String {
        val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
        format.timeZone = TimeZone.getTimeZone("UTC")
        return format.format(Date())
    }

    /**
     * Increments the count for [trackId] and returns the new count, or null on
     * any failure (no access token, non-2xx, network, unreadable reply).
     * Blocking.
     *
     * A pair with no row yet is appended: count 1 normally, or count 2 with
     * `backfilled` TRUE when the track was already liked before this press —
     * the like that is being counted plus the one that must have happened
     * earlier, the same rule the desktop applies.
     */
    fun increment(
        prefs: SharedPreferences,
        target: Target,
        trackId: String,
        wasAlreadyLiked: Boolean = false,
    ): Int? {
        val token = GoogleTokens.freshOrNull(prefs, GoogleTokens.COUNTER) ?: return null
        return try {
            // A read that failed is not the same as a pair with no row: append
            // on a failed read would duplicate the row and restart its count.
            val body = get(token, "$API_BASE/${target.spreadsheetId}/values/${encode(SHEET)}")
                ?: return null
            val existing = findRow(body, target.userId, trackId)
            val now = nowIso()
            if (existing != null) {
                val (row, current) = existing
                val next = current + 1
                val base = "$API_BASE/${target.spreadsheetId}/values"
                if (!update(token, "$base/${encode("$SHEET!C$row")}", next.toString())) return null
                // Column D (backfilled) is left alone: it records how the row
                // started, not how it was last touched.
                // The count is already on the sheet at this point, so a failed
                // timestamp write is reported as the success it mostly is.
                update(token, "$base/${encode("$SHEET!E$row")}", now)
                next
            } else {
                val next = if (wasAlreadyLiked) 2 else 1
                val row = JSONArray(
                    listOf(
                        target.userId,
                        trackId,
                        next.toString(),
                        if (wasAlreadyLiked) "TRUE" else "FALSE",
                        now,
                    ),
                )
                append(token, target.spreadsheetId, row) ?: return null
                next
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun get(token: String, url: String): String? {
        val connection = open(token, url, "GET")
        if (connection.responseCode !in 200..299) return null
        return readBody(connection)
    }

    /** One cell write. False when the sheet refused it. */
    private fun update(token: String, url: String, value: String): Boolean {
        val connection = open(token, "$url?valueInputOption=RAW", "PUT")
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/json")
        val body = JSONObject().put("values", JSONArray().put(JSONArray().put(value)))
        OutputStreamWriter(connection.outputStream).use { it.write(body.toString()) }
        return connection.responseCode in 200..299
    }

    /** Appends [row] to the tab. Returns null when the sheet refused it. */
    private fun append(token: String, spreadsheetId: String, row: JSONArray): Int? {
        val url = "$API_BASE/$spreadsheetId/values/${encode(SHEET)}:append" +
            "?valueInputOption=RAW&insertDataOption=INSERT_ROWS"
        val connection = open(token, url, "POST")
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/json")
        val body = JSONObject().put("values", JSONArray().put(row))
        OutputStreamWriter(connection.outputStream).use { it.write(body.toString()) }
        if (connection.responseCode !in 200..299) return null
        val updated = runCatching {
            JSONObject(readBody(connection).orEmpty())
                .optJSONObject("updates")
                ?.optString("updatedRange")
        }.getOrNull()
        return rowFromA1Range(updated) ?: 0
    }

    private fun open(token: String, url: String, method: String): HttpURLConnection {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.requestMethod = method
        connection.connectTimeout = HTTP_TIMEOUT_MS
        connection.readTimeout = HTTP_TIMEOUT_MS
        connection.setRequestProperty("Authorization", "Bearer $token")
        return connection
    }

    private fun readBody(connection: HttpURLConnection): String? = try {
        BufferedReader(connection.inputStream.reader()).use { it.readText() }
    } catch (_: Exception) {
        null
    }

    private fun encode(range: String): String = URLEncoder.encode(range, Charsets.UTF_8.name())
}
