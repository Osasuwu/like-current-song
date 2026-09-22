package com.osasuwu.like_spotify

import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/**
 * The per-install like bookkeeping: how often each track and each artist has
 * been liked, when each track was last liked, and which artists have already
 * been auto-followed.
 *
 * All four live in [AppConstants.PREFS] and nowhere else. The Flutter layer
 * used to keep its own copies in the `shared_preferences` store, so a like made
 * in the app and a like made with the media button counted into two maps that
 * never met -- the follow-artist threshold and the like cooldown both stopped
 * working for anyone who used both (#197). Dart now reaches these maps over the
 * service method channel instead, which makes this the only copy.
 *
 * The JSON shaping is pure and unit-tested; the [SharedPreferences] shell
 * around it is a thin wrapper, the same split [BackgroundLog] uses. Every
 * read-modify-write is synchronized, because the background worker and the
 * Flutter engine can be counting the same like from two threads.
 */
object LocalCounters {

    /** Which count map an id belongs to. [id] is the value carried on the channel. */
    enum class Kind(val id: String, val prefsKey: String) {
        TRACK("track", AppConstants.KEY_TRACK_LIKE_COUNTS),
        ARTIST("artist", AppConstants.KEY_ARTIST_LIKE_COUNTS);

        companion object {
            /** Null for anything but the two spellings above -- a caller typo is not a track. */
            fun fromId(id: String?): Kind? = values().firstOrNull { it.id == id }
        }
    }

    // ---- Pure shaping ----------------------------------------------

    /**
     * The stored count map. Anything unreadable -- truncated by a kill
     * mid-write, or written in a shape a past version used -- degrades to
     * empty, because losing a count is better than failing a like over it.
     */
    fun parseCounts(raw: String?): Map<String, Int> = parse(raw) { json, key -> json.optInt(key, 0) }

    /** The stored last-liked map, epoch milliseconds UTC. Degrades like [parseCounts]. */
    fun parseTimestamps(raw: String?): Map<String, Long> = parse(raw) { json, key -> json.optLong(key, 0L) }

    fun encode(values: Map<String, Number>): String {
        val json = JSONObject()
        values.forEach { (id, value) -> json.put(id, value) }
        return json.toString()
    }

    /** [raw] with [id] counted once more; an id that was never counted lands on 1. */
    fun incremented(raw: String?, id: String): Map<String, Int> {
        val counts = parseCounts(raw)
        return counts + (id to (counts[id] ?: 0) + 1)
    }

    /**
     * [existing] with [incoming] added on per key.
     *
     * The two stores this folds together never shared a like: before #197 a
     * like counted into the Dart store *or* into this one, never both, so a
     * track liked three times in the app and twice with the media button is
     * genuinely five likes and has to migrate as five. Keeping the larger of
     * the two would throw the smaller half away -- and it is the users who
     * used both halves, the ones this fixes, who would lose the most.
     *
     * Adding is only right once, which is why [merge] will not do it twice.
     */
    fun summed(existing: Map<String, Int>, incoming: Map<String, Int>): Map<String, Int> {
        val out = LinkedHashMap(existing)
        incoming.forEach { (id, value) -> out[id] = (out[id] ?: 0) + value }
        return out
    }

    /**
     * [existing] with [incoming] folded in, keeping the larger value per key --
     * for the last-liked map, where that reads as "the later like wins".
     *
     * Counts use [summed] instead: two likes are two likes, but a track has
     * only ever been last liked once.
     */
    fun <T : Comparable<T>> merged(existing: Map<String, T>, incoming: Map<String, T>): Map<String, T> {
        val out = LinkedHashMap(existing)
        incoming.forEach { (id, value) ->
            val current = out[id]
            if (current == null || value > current) out[id] = value
        }
        return out
    }

    /** The followed-artist set, stored as a JSON array. Degrades to empty. */
    fun parseIds(raw: String?): Set<String> {
        val parsed = runCatching { JSONArray(raw ?: "[]") }.getOrDefault(JSONArray())
        val out = LinkedHashSet<String>(parsed.length())
        for (i in 0 until parsed.length()) {
            parsed.optString(i).takeIf { it.isNotEmpty() }?.let { out.add(it) }
        }
        return out
    }

    fun encodeIds(ids: Set<String>): String {
        val json = JSONArray()
        ids.forEach { json.put(it) }
        return json.toString()
    }

    /**
     * Channel arguments arrive as whatever integer width the codec picked, so
     * a count can turn up as either an Int or a Long. Non-numeric values are
     * dropped rather than guessed at.
     */
    fun numbersFrom(raw: Map<*, *>?): Map<String, Long> {
        val out = LinkedHashMap<String, Long>()
        raw?.forEach { (key, value) ->
            val id = key as? String ?: return@forEach
            val number = value as? Number ?: return@forEach
            out[id] = number.toLong()
        }
        return out
    }

    // ---- Counts ----------------------------------------------

    fun counts(prefs: SharedPreferences, kind: Kind): Map<String, Int> =
        parseCounts(prefs.getString(kind.prefsKey, null))

    fun count(prefs: SharedPreferences, kind: Kind, id: String): Int = counts(prefs, kind)[id] ?: 0

    /** The count for [id], one higher than before, stored and returned. */
    @Synchronized
    fun increment(prefs: SharedPreferences, kind: Kind, id: String): Int {
        val updated = incremented(prefs.getString(kind.prefsKey, null), id)
        prefs.edit().putString(kind.prefsKey, encode(updated)).apply()
        return updated.getValue(id)
    }

    // ---- Last liked ----------------------------------------------

    /** When [id] was last liked, or null when it never was. */
    fun lastLikedAt(prefs: SharedPreferences, id: String): Long? =
        parseTimestamps(prefs.getString(AppConstants.KEY_TRACK_LAST_LIKED_AT, null))[id]
            ?.takeIf { it > 0L }

    @Synchronized
    fun recordLikedAt(prefs: SharedPreferences, id: String, atEpochMillis: Long) {
        val updated = parseTimestamps(prefs.getString(AppConstants.KEY_TRACK_LAST_LIKED_AT, null)) +
            (id to atEpochMillis)
        prefs.edit().putString(AppConstants.KEY_TRACK_LAST_LIKED_AT, encode(updated)).apply()
    }

    // ---- Followed artists ----------------------------------------------

    /**
     * The artists this app has already auto-followed. The threshold rule fires
     * on "liked often enough and not followed yet", so without this set a
     * threshold tested with `>=` would re-follow on every later like.
     */
    fun followedArtists(prefs: SharedPreferences): Set<String> =
        parseIds(prefs.getString(AppConstants.KEY_FOLLOWED_ARTISTS, null))

    /**
     * Whether the follow rule should fire for [id] right now: its count is at
     * or past [threshold], and it is not in [followed] already.
     *
     * The one decision both background paths make, kept here so it is made the
     * same way in both and can be tested without an Android runtime. The test
     * used to be `count == threshold`, which needed the count to land on the
     * threshold exactly -- so a like counted in a store this one could not see
     * meant the artist was never followed at all, not merely followed late
     * (#197). `>=` also covers a threshold the user lowers below a count they
     * already have, and the migration pushing a count past it in one jump.
     */
    fun shouldFollow(count: Int, threshold: Int, followed: Set<String>, id: String): Boolean =
        count >= threshold && id !in followed

    @Synchronized
    fun markArtistFollowed(prefs: SharedPreferences, id: String) {
        val updated = followedArtists(prefs) + id
        prefs.edit().putString(AppConstants.KEY_FOLLOWED_ARTISTS, encodeIds(updated)).apply()
    }

    // ---- Migration ----------------------------------------------

    /**
     * Folds the counters Dart kept in its own store before #197 into this one:
     * counts are added ([summed]), last-liked times take the later ([merged]).
     *
     * Returns false, having done nothing, if that fold already happened. Adding
     * is the honest arithmetic -- the two stores never shared a like -- but it
     * is right exactly once, so the flag that records it is written in the same
     * commit as the counts and guards every later call. Dart may therefore call
     * this whenever it is unsure rather than having to prove it ran once, which
     * it cannot: the process can die between this write and Dart clearing its
     * own copy.
     */
    @Synchronized
    fun merge(
        prefs: SharedPreferences,
        tracks: Map<String, Int>,
        artists: Map<String, Int>,
        lastLikedAt: Map<String, Long>,
    ): Boolean {
        if (prefs.getBoolean(AppConstants.KEY_COUNTERS_MERGED, false)) return false

        val editor = prefs.edit()
        mapOf(Kind.TRACK to tracks, Kind.ARTIST to artists).forEach { (kind, incoming) ->
            editor.putString(kind.prefsKey, encode(summed(counts(prefs, kind), incoming)))
        }

        val existingStamps = parseTimestamps(prefs.getString(AppConstants.KEY_TRACK_LAST_LIKED_AT, null))
        editor.putString(AppConstants.KEY_TRACK_LAST_LIKED_AT, encode(merged(existingStamps, lastLikedAt)))

        editor.putBoolean(AppConstants.KEY_COUNTERS_MERGED, true)
        editor.apply()
        return true
    }

    private fun <T> parse(raw: String?, read: (JSONObject, String) -> T): Map<String, T> {
        val json = runCatching { JSONObject(raw ?: "{}") }.getOrDefault(JSONObject())
        val out = LinkedHashMap<String, T>(json.length())
        json.keys().forEach { key -> out[key] = read(json, key) }
        return out
    }
}
