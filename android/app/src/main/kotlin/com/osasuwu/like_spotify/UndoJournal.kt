package com.osasuwu.like_spotify

import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

/**
 * One effect a like performed that an undo can revert (#267). Each leg is
 * recorded only once the service has confirmed it, so an undo reverses
 * exactly what happened and nothing else.
 *
 * New kinds join here as later slices journal more of the press: the
 * counters (#272), best promotion and auto-follow (#273), YouTube Music (#274).
 */
sealed class UndoLeg {
    /**
     * The track was rated a like on its service; [alreadySaved] means it was
     * before the press. [sessionSong] names the song when the rating went
     * through the player's media session (YouTube Music, #274), which is
     * where it has to be taken back; null means through the service's API.
     * [videoId] names the video a YouTube Data API rating went to, the only
     * one its undo may rate (#274), and [disliked] that the user had
     * disliked it before the press, so the undo puts the dislike back.
     */
    data class NativeSave(
        val alreadySaved: Boolean,
        val sessionSong: String? = null,
        val videoId: String? = null,
        val disliked: Boolean = false,
    ) : UndoLeg()

    /**
     * The track was appended to the like playlist [playlistId]. [itemId]
     * names the playlist item the add made, where the service has one
     * (YouTube Music, #274), so the undo takes out that item and no other;
     * null on Spotify, which removes a track only by URI.
     */
    data class LikePlaylistAdd(val playlistId: String, val itemId: String? = null) : UndoLeg()

    /** Every one of [copies] copies of the track was removed from the archive playlist [playlistId]. */
    data class ArchiveRemove(val playlistId: String, val copies: Int) : UndoLeg()

    /**
     * The like promoted the track into the best playlist [playlistId] (#273).
     * Recorded only for a promotion the like made: a press that found the
     * track in best already changed nothing there. [itemId] as for
     * [LikePlaylistAdd].
     */
    data class BestPromote(val playlistId: String, val itemId: String? = null) : UndoLeg()

    /**
     * The like added the track to this device's distinct tracks of [artistId],
     * the count follow-artist falls back on (#273). Recorded only when the
     * track was new there.
     */
    data class ArtistTrack(val artistId: String) : UndoLeg()

    /**
     * The like appended the (user, [artistId], track) row to the counter
     * sheet [sheet]'s artist tab (#273). Recorded only for a row this like
     * wrote: a track the sheet already counted for the artist wrote nothing.
     */
    data class ArtistTrackRow(val artistId: String, val sheet: LikeCounter.Target) : UndoLeg()

    /**
     * The like auto-followed [artistId] (#273); [alreadyFollowed] means the
     * user followed the artist before the press, and the undo leaves it so.
     */
    data class ArtistFollow(val artistId: String, val alreadyFollowed: Boolean) : UndoLeg()

    /**
     * The like stamped the track's last-liked time, which the like cooldown
     * reads; [previous] is the stamp it replaced, null when there was none.
     */
    data class CooldownStamp(val previous: Long?, val key: String? = null) : UndoLeg()

    /**
     * The like added one to the track's counter (#272): on the Google Sheet
     * [sheet] names, or on this device's fallback counter when [sheet] is
     * null. The undo lowers that same counter and never the other one.
     */
    data class TrackCount(val sheet: LikeCounter.Target?) : UndoLeg()
}

/**
 * The undo gesture's journal (#267): repeating the trigger within
 * [WINDOW_MS] of a like undoes that like. The detector does not know about
 * undo; the service asks [onPress] on every matched trigger, and the worker
 * records what each like did as it goes.
 *
 * Kept in [SharedPreferences] because the press arrives in the service and
 * the like runs in the worker, and either may outlive the other. Every
 * read-modify-write holds this object's lock, so two presses or a press and
 * the worker cannot interleave. Only the latest entry decides a press; older
 * ones are kept, up to [MAX_ENTRIES], so a superseded like's late writes land
 * on its own entry instead of on the one the user can still undo.
 */
object UndoJournal {

    /** The undo window, fixed by the decision #267 cites. */
    const val WINDOW_MS = 10_000L

    private const val MAX_ENTRIES = 5

    enum class State { LIKING, LIKED, UNDOING, DONE }

    /** What the worker must do once a like's legs are done; see [finishLike]. */
    enum class Finish {
        /** Nothing: no undo was asked for, or the entry is gone. */
        NONE,

        /** An undo arrived mid-like; run it now, against the recorded legs. */
        RUN_UNDO,

        /** An undo arrived mid-like, but the like performed nothing to revert. */
        UNDO_NOTHING,
    }

    /** The service's answer to a matched trigger; see [onPress]. */
    sealed class Press {
        /** A like. [afterUndo] means an undo is still running and the like must queue behind it. */
        data class Like(val afterUndo: Boolean) : Press()

        /** Undo the like journalled under [pressId]; the entry is already marked [State.UNDOING]. */
        data class Undo(val pressId: String) : Press()

        /** The like is still running; it will undo itself when it finishes. */
        object QueueUndo : Press()

        /** The window already has an undo in hand. */
        object Ignore : Press()
    }

    data class Entry(
        val id: String,
        val state: State,
        val trackId: String?,
        val trackUri: String?,
        val legs: List<UndoLeg>,
        /** The service the like went to; entries from before #274 are Spotify's. */
        val provider: MusicProvider = MusicProvider.SPOTIFY,
    )

    /**
     * Decides what a matched, un-vetoed trigger means, and records the
     * decision before returning it so the next press sees it.
     *
     * The window runs from the like's tone, when the user learns it happened;
     * while the like is still running it runs from the press. A negative
     * distance (the clock moved back) counts as outside.
     */
    @Synchronized
    fun onPress(prefs: SharedPreferences, now: Long): Press {
        val entries = load(prefs)
        val latest = entries.lastOrNull() ?: return Press.Like(afterUndo = false)
        val state = State.valueOf(latest.getString(F_STATE))
        val anchor = if (state == State.LIKING) latest.getLong(F_PRESSED_AT) else latest.optLong(F_LIKED_AT)
        val elapsed = now - anchor
        val open = elapsed in 0..WINDOW_MS
        return when {
            state == State.DONE -> Press.Like(afterUndo = false)
            !open -> Press.Like(afterUndo = state == State.UNDOING)
            state == State.LIKING && latest.optBoolean(F_UNDO_QUEUED) -> Press.Ignore
            state == State.LIKING -> {
                latest.put(F_UNDO_QUEUED, true)
                save(prefs, entries)
                Press.QueueUndo
            }
            state == State.LIKED -> {
                latest.put(F_STATE, State.UNDOING.name)
                save(prefs, entries)
                Press.Undo(latest.getString(F_ID))
            }
            else -> Press.Ignore
        }
    }

    /** The like [pressId] can still be undone until [closesAt], inclusive. */
    data class Window(val pressId: String, val closesAt: Long)

    /**
     * The like an Undo action may offer at [now] (#269): the latest entry,
     * finished with something to revert, within [WINDOW_MS] of its tone.
     * Null while the like runs, once any undo has started, and after the
     * window — the same moments a repeat press would no longer undo.
     */
    @Synchronized
    fun openWindow(prefs: SharedPreferences, now: Long): Window? {
        val latest = load(prefs).lastOrNull() ?: return null
        if (!undoable(latest, now)) return null
        return Window(latest.getString(F_ID), latest.getLong(F_LIKED_AT) + WINDOW_MS)
    }

    /**
     * A tap on the Undo action offered for [pressId]. Starts the undo, exactly
     * as a repeat press inside the window would, and returns true; returns
     * false and changes nothing when the action is stale — the window passed,
     * a newer like took it over, or an undo already started.
     */
    @Synchronized
    fun requestUndo(prefs: SharedPreferences, pressId: String, now: Long): Boolean {
        val entries = load(prefs)
        val latest = entries.lastOrNull() ?: return false
        if (latest.getString(F_ID) != pressId || !undoable(latest, now)) return false
        latest.put(F_STATE, State.UNDOING.name)
        save(prefs, entries)
        return true
    }

    private fun undoable(entry: JSONObject, now: Long): Boolean =
        State.valueOf(entry.getString(F_STATE)) == State.LIKED &&
            (now - entry.optLong(F_LIKED_AT)) in 0..WINDOW_MS

    /** Opens a journal entry for a like the worker is about to run; returns its id. */
    @Synchronized
    fun beginLike(prefs: SharedPreferences, now: Long, provider: MusicProvider = MusicProvider.SPOTIFY): String {
        val id = java.util.UUID.randomUUID().toString()
        val entries = load(prefs)
        entries += JSONObject()
            .put(F_ID, id)
            .put(F_PRESSED_AT, now)
            .put(F_STATE, State.LIKING.name)
            .put(F_PROVIDER, provider.id)
            .put(F_LEGS, JSONArray())
        save(prefs, entries.takeLast(MAX_ENTRIES))
        return id
    }

    @Synchronized
    fun setTrack(prefs: SharedPreferences, id: String, trackId: String, trackUri: String) {
        update(prefs, id) { it.put(F_TRACK_ID, trackId).put(F_TRACK_URI, trackUri) }
    }

    /** Appends [leg] to the entry [id]; a no-op when the entry is gone. */
    @Synchronized
    fun recordLeg(prefs: SharedPreferences, id: String, leg: UndoLeg) {
        update(prefs, id) { it.getJSONArray(F_LEGS).put(encode(leg)) }
    }

    /**
     * Closes the like [id] at [now], when its tone plays, and says whether an
     * undo queued during it must run. A like that recorded no leg leaves
     * nothing to undo and opens no window.
     */
    @Synchronized
    fun finishLike(prefs: SharedPreferences, id: String, now: Long): Finish {
        var finish = Finish.NONE
        update(prefs, id) { entry ->
            val hasLegs = entry.getJSONArray(F_LEGS).length() > 0
            val queued = entry.optBoolean(F_UNDO_QUEUED)
            entry.put(F_LIKED_AT, now)
            val next = when {
                queued && hasLegs -> State.UNDOING.also { finish = Finish.RUN_UNDO }
                queued -> State.DONE.also { finish = Finish.UNDO_NOTHING }
                hasLegs -> State.LIKED
                else -> State.DONE
            }
            entry.put(F_STATE, next.name)
        }
        return finish
    }

    /**
     * Whether an undo of [id] has been accepted, by a repeat or an Undo tap
     * after the like's tone, and not yet run. A like still running reads
     * this to skip work its undo would only revert.
     */
    @Synchronized
    fun undoAccepted(prefs: SharedPreferences, id: String): Boolean =
        load(prefs).firstOrNull { it.getString(F_ID) == id }?.getString(F_STATE) == State.UNDOING.name

    /** Closes the undo of [id]; the next press likes again. */
    @Synchronized
    fun finishUndo(prefs: SharedPreferences, id: String) {
        update(prefs, id) { it.put(F_STATE, State.DONE.name) }
    }

    @Synchronized
    fun entry(prefs: SharedPreferences, id: String): Entry? {
        val json = load(prefs).firstOrNull { it.getString(F_ID) == id } ?: return null
        val legs = json.getJSONArray(F_LEGS)
        return Entry(
            id = id,
            state = State.valueOf(json.getString(F_STATE)),
            trackId = json.optString(F_TRACK_ID).ifBlank { null },
            trackUri = json.optString(F_TRACK_URI).ifBlank { null },
            legs = (0 until legs.length()).mapNotNull { decode(legs.getJSONObject(it)) },
            provider = MusicProvider.fromId(json.optString(F_PROVIDER).ifBlank { null }),
        )
    }

    private fun update(prefs: SharedPreferences, id: String, change: (JSONObject) -> Unit) {
        val entries = load(prefs)
        val entry = entries.firstOrNull { it.getString(F_ID) == id } ?: return
        change(entry)
        save(prefs, entries)
    }

    /** The stored entries, oldest first. An absent or unreadable journal reads as empty. */
    private fun load(prefs: SharedPreferences): MutableList<JSONObject> {
        val raw = prefs.getString(AppConstants.KEY_UNDO_JOURNAL, null) ?: return mutableListOf()
        return try {
            val array = JSONArray(raw)
            MutableList(array.length()) { array.getJSONObject(it) }
        } catch (_: Exception) {
            mutableListOf()
        }
    }

    private fun save(prefs: SharedPreferences, entries: List<JSONObject>) {
        prefs.edit().putString(AppConstants.KEY_UNDO_JOURNAL, JSONArray(entries).toString()).apply()
    }

    private fun encode(leg: UndoLeg): JSONObject = when (leg) {
        is UndoLeg.NativeSave -> JSONObject()
            .put(F_KIND, K_NATIVE_SAVE)
            .put("alreadySaved", leg.alreadySaved)
            .putOpt("sessionSong", leg.sessionSong)
            .putOpt("videoId", leg.videoId)
            .apply { if (leg.disliked) put("disliked", true) }
        is UndoLeg.LikePlaylistAdd -> JSONObject()
            .put(F_KIND, K_LIKE_PLAYLIST_ADD)
            .put("playlistId", leg.playlistId)
            .putOpt("itemId", leg.itemId)
        is UndoLeg.ArchiveRemove -> JSONObject()
            .put(F_KIND, K_ARCHIVE_REMOVE)
            .put("playlistId", leg.playlistId)
            .put("copies", leg.copies)
        is UndoLeg.BestPromote -> JSONObject()
            .put(F_KIND, K_BEST_PROMOTE)
            .put("playlistId", leg.playlistId)
            .putOpt("itemId", leg.itemId)
        is UndoLeg.ArtistTrack -> JSONObject().put(F_KIND, K_ARTIST_TRACK).put("artistId", leg.artistId)
        is UndoLeg.ArtistTrackRow -> JSONObject()
            .put(F_KIND, K_ARTIST_TRACK_ROW)
            .put("artistId", leg.artistId)
            .put("spreadsheetId", leg.sheet.spreadsheetId)
            .put("userId", leg.sheet.userId)
        is UndoLeg.ArtistFollow -> JSONObject()
            .put(F_KIND, K_ARTIST_FOLLOW)
            .put("artistId", leg.artistId)
            .put("alreadyFollowed", leg.alreadyFollowed)
        // A null previous stamp is stored as an absent field.
        is UndoLeg.CooldownStamp -> JSONObject()
            .put(F_KIND, K_COOLDOWN_STAMP)
            .put("previous", leg.previous)
            .putOpt("key", leg.key)
        is UndoLeg.TrackCount -> JSONObject().put(F_KIND, K_TRACK_COUNT).apply {
            val sheet = leg.sheet
            if (sheet == null) {
                put("store", STORE_LOCAL)
            } else {
                put("store", STORE_SHEET).put("spreadsheetId", sheet.spreadsheetId).put("userId", sheet.userId)
            }
        }
    }

    private fun decode(json: JSONObject): UndoLeg? = when (json.optString(F_KIND)) {
        K_NATIVE_SAVE -> UndoLeg.NativeSave(
            json.getBoolean("alreadySaved"),
            sessionSong = json.optString("sessionSong").ifBlank { null },
            videoId = json.optString("videoId").ifBlank { null },
            disliked = json.optBoolean("disliked"),
        )
        K_LIKE_PLAYLIST_ADD -> UndoLeg.LikePlaylistAdd(json.getString("playlistId"), json.optString("itemId").ifBlank { null })
        K_ARCHIVE_REMOVE -> UndoLeg.ArchiveRemove(json.getString("playlistId"), json.getInt("copies"))
        K_BEST_PROMOTE -> UndoLeg.BestPromote(json.getString("playlistId"), json.optString("itemId").ifBlank { null })
        K_ARTIST_TRACK -> UndoLeg.ArtistTrack(json.getString("artistId"))
        K_ARTIST_TRACK_ROW -> UndoLeg.ArtistTrackRow(
            json.getString("artistId"),
            LikeCounter.Target(json.getString("spreadsheetId"), json.getString("userId")),
        )
        K_ARTIST_FOLLOW -> UndoLeg.ArtistFollow(json.getString("artistId"), json.getBoolean("alreadyFollowed"))
        K_COOLDOWN_STAMP -> UndoLeg.CooldownStamp(
            if (json.has("previous")) json.getLong("previous") else null,
            json.optString("key").ifBlank { null },
        )
        K_TRACK_COUNT -> when (json.optString("store")) {
            STORE_LOCAL -> UndoLeg.TrackCount(sheet = null)
            STORE_SHEET -> UndoLeg.TrackCount(
                LikeCounter.Target(json.getString("spreadsheetId"), json.getString("userId")),
            )
            // A store this build does not know: skip the leg rather than lower the wrong counter.
            else -> null
        }
        else -> null
    }

    private const val F_ID = "id"
    private const val F_PRESSED_AT = "pressedAt"
    private const val F_LIKED_AT = "likedAt"
    private const val F_STATE = "state"
    private const val F_UNDO_QUEUED = "undoQueued"
    private const val F_TRACK_ID = "trackId"
    private const val F_TRACK_URI = "trackUri"
    private const val F_LEGS = "legs"
    private const val F_PROVIDER = "provider"
    private const val F_KIND = "kind"
    private const val K_NATIVE_SAVE = "native_save"
    private const val K_LIKE_PLAYLIST_ADD = "like_playlist_add"
    private const val K_ARCHIVE_REMOVE = "archive_remove"
    private const val K_BEST_PROMOTE = "best_promote"
    private const val K_ARTIST_TRACK = "artist_track"
    private const val K_ARTIST_TRACK_ROW = "artist_track_row"
    private const val K_ARTIST_FOLLOW = "artist_follow"
    private const val K_COOLDOWN_STAMP = "cooldown_stamp"
    private const val K_TRACK_COUNT = "track_count"
    private const val STORE_SHEET = "sheet"
    private const val STORE_LOCAL = "local"
}
