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
 * The sheet has a tab named [SHEET] whose first row is
 * [CounterSheetSchema.LIKES_HEADER]. A row is keyed by
 * (user id, track id), where both ids come from the music service the like
 * went through, so the phone and the computer add to the same count per
 * account.
 */
object LikeCounter {
    private const val HTTP_TIMEOUT_MS = 5_000
    private const val API_BASE = "https://sheets.googleapis.com/v4/spreadsheets"

    /** The tab the counts live on, from the schema all three halves share. */
    const val SHEET = CounterSheetSchema.LIKES_TAB

    /** Where one like is counted. The access token is fetched per call. */
    data class Target(val spreadsheetId: String, val userId: String)

    /**
     * What one counted like did: [count] when the sheet took it, otherwise
     * [failure] — a sentence for the Logs screen — and the status behind it.
     *
     * The counter used to answer a bare null, so a like that was not counted
     * reached the user as "the shared counter did not answer" whatever had
     * happened, or as nothing at all on the Spotify path (#200).
     */
    data class CountOutcome(val count: Int?, val failure: String?, val httpCode: Int?) {
        companion object {
            fun counted(count: Int) = CountOutcome(count, null, null)

            fun failed(reason: String, httpCode: Int? = null) =
                CountOutcome(null, reason, httpCode)
        }
    }

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
     *
     * A pair with more than one row — damage from before #193, which a sheet
     * cannot be repaired of from here — resolves to the **topmost** of them.
     * The Dart half applies the same rule
     * (`google_sheets_like_count_repository.dart`), so both keep adding to
     * one row instead of drifting further apart; do not change this to the
     * last match without changing that too.
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
     * Increments the count for [trackId], as a [CountOutcome]: the new count,
     * or why the sheet did not take it (no usable token, non-2xx, network,
     * unreadable reply). Blocking.
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
    ): CountOutcome {
        val token = try {
            GoogleTokens.fresh(prefs, GoogleTokens.COUNTER)
        } catch (failure: GoogleTokens.RefreshFailure) {
            return CountOutcome.failed(tokenRefusedMessage(failure), failure.httpCode)
        } catch (e: Exception) {
            return CountOutcome.failed(unreachable(e))
        }
        return try {
            // A read that failed is not the same as a pair with no row: append
            // on a failed read would duplicate the row and restart its count.
            val read = get(token, "$API_BASE/${target.spreadsheetId}/values/${encode(SHEET)}")
            val body = read.body
                ?: return CountOutcome.failed("the counter sheet could not be read", read.status)
            val existing = findRow(body, target.userId, trackId)
            val now = nowIso()
            if (existing != null) {
                val (row, current) = existing
                val next = current + 1
                val base = "$API_BASE/${target.spreadsheetId}/values"
                val countCell = encode("$SHEET!${CounterSheetSchema.COUNT_COLUMN}$row")
                val written = update(token, "$base/$countCell", next)
                if (written !in 200..299) {
                    return CountOutcome.failed("the counter sheet refused the new count", written)
                }
                // `backfilled` is left alone: it records how the row started,
                // not how it was last touched.
                // The count is already on the sheet at this point, so a failed
                // timestamp write is reported as the success it mostly is.
                val stampCell = encode("$SHEET!${CounterSheetSchema.UPDATED_AT_COLUMN}$row")
                update(token, "$base/$stampCell", now)
                CountOutcome.counted(next)
            } else {
                val next = if (wasAlreadyLiked) 2 else 1
                val row = listOf(
                    target.userId,
                    trackId,
                    next,
                    if (wasAlreadyLiked) "TRUE" else "FALSE",
                    now,
                )
                val (status, _) = append(token, target.spreadsheetId, row)
                if (status !in 200..299) {
                    return CountOutcome.failed("the counter sheet refused a new row", status)
                }
                CountOutcome.counted(next)
            }
        } catch (e: Exception) {
            CountOutcome.failed(unreachable(e))
        }
    }

    /**
     * Why a refused token means this like was not counted, in the Logs
     * screen's words.
     *
     * Pure, and the twin of `likeCounterRefreshFailureMessage` in
     * `lib/data/likes/like_counter_token_error.dart` — the two halves like the
     * same songs into the same sheet, so they had better explain a refusal the
     * same way. Note what the codes mean: a revoked grant really is fixed by
     * signing in again, a rejected client never is, and telling a user with a
     * wrong client secret to sign in again is what #200 was about.
     */
    fun tokenRefusedMessage(failure: GoogleTokens.RefreshFailure): String = when {
        failure.error == "invalid_client" || failure.error == "unauthorized_client" ->
            "Google rejected the counter's client ID or secret (${failure.error}). " +
                "Check both under Connected services → Shared like counter"
        failure.error == "invalid_grant" ->
            "the counter's Google sign-in is no longer valid. Sign in again " +
                "under Connected services → Shared like counter"
        failure.error == "invalid_scope" ->
            "Google refused the spreadsheet scope the counter needs " +
                "(invalid_scope). Sign the counter in again under Connected " +
                "services → Shared like counter"
        // No status means the request never went out: the client id or the
        // refresh token is missing, i.e. nobody ever signed the counter in.
        failure.httpCode == null ->
            "the counter is not signed in to Google. Sign in under Connected " +
                "services → Shared like counter"
        else ->
            "Google would not renew the counter's token " +
                "(${failure.error ?: "HTTP ${failure.httpCode}"})"
    }

    private fun unreachable(e: Exception): String =
        "the counter sheet could not be reached: ${e.javaClass.simpleName}"

    /** One call's answer: the status, and the body when it was a success. */
    private class Answer(val status: Int, val body: String?)

    private fun get(token: String, url: String): Answer {
        val connection = open(token, url, "GET")
        val status = connection.responseCode
        return Answer(status, if (status in 200..299) readBody(connection) else null)
    }

    /**
     * The `values` body of a write, one row of [cells].
     *
     * Every write goes out with `valueInputOption=RAW`, so the sheet stores
     * each cell as the JSON type it arrives in — a count sent as `"1"` lands
     * as text next to the number the Dart half writes for the same column.
     * Pass an `Int` for a number and a `String` for text.
     */
    fun writeBody(cells: List<Any>): String =
        JSONObject().put("values", JSONArray().put(JSONArray(cells))).toString()

    /** One cell write; answers the status the sheet gave it. */
    private fun update(token: String, url: String, value: Any): Int {
        val connection = open(token, "$url?valueInputOption=RAW", "PUT")
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/json")
        OutputStreamWriter(connection.outputStream).use { it.write(writeBody(listOf(value))) }
        return connection.responseCode
    }

    /**
     * Appends [row] to the tab: the status, and the row it landed on when the
     * sheet said where.
     */
    private fun append(token: String, spreadsheetId: String, row: List<Any>): Pair<Int, Int?> {
        val url = "$API_BASE/$spreadsheetId/values/${encode(SHEET)}:append" +
            "?valueInputOption=RAW&insertDataOption=INSERT_ROWS"
        val connection = open(token, url, "POST")
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/json")
        OutputStreamWriter(connection.outputStream).use { it.write(writeBody(row)) }
        val status = connection.responseCode
        if (status !in 200..299) return status to null
        val updated = runCatching {
            JSONObject(readBody(connection).orEmpty())
                .optJSONObject("updates")
                ?.optString("updatedRange")
        }.getOrNull()
        return status to rowFromA1Range(updated)
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
