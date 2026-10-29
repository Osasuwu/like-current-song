package com.osasuwu.like_spotify

import android.content.SharedPreferences

/**
 * The best-playlist rule, made the same way by the Spotify worker and the
 * YouTube Music actions (#245): once a track's count is at or past the
 * threshold and this device has not promoted it yet, put it in the best
 * playlist, once.
 *
 * Two things stop the 4th, 5th… like from adding it again:
 *
 *  * the promoted-memory ([LocalCounters.promotedTracks]), written only after
 *    the track is in the playlist, so a failed add is retried on the next
 *    like;
 *  * a membership check before the add. The memory is per device and starts
 *    empty, while the count is shared through the counter sheet and was
 *    counted long before the memory existed. A track another device promoted,
 *    or one promoted before this memory existed, is past the threshold and not
 *    remembered here -- adding it would put a second copy in the playlist,
 *    because both services accept duplicates. Found already there, it is only
 *    remembered.
 *
 * The network calls are the caller's, passed in, so the decision and the
 * bookkeeping are tested here without an Android runtime or a network.
 */
object BestPromotion {

    enum class Outcome {
        /** Below the threshold, or promoted before: nothing was asked of the service. */
        NOT_DUE,

        /** Already in the playlist: nothing added, and now remembered. */
        ALREADY_IN_PLAYLIST,

        /** Added to the playlist, and now remembered. */
        ADDED,

        /** The service did not take it: not remembered, so the next like retries. */
        NOT_ADDED,
    }

    /**
     * Runs the rule for the track stored under [key] at [count] likes.
     *
     * [isInPlaylist] and [add] are only called when the rule is due, in that
     * order, and [add] only when the track is not there yet. [add] returns
     * whether the track landed. Either may throw; the throw propagates and
     * nothing is remembered, which is the same as [Outcome.NOT_ADDED].
     */
    fun run(
        prefs: SharedPreferences,
        count: Int,
        threshold: Int,
        key: String,
        isInPlaylist: () -> Boolean,
        add: () -> Boolean,
    ): Outcome {
        if (!LocalCounters.shouldPromote(count, threshold, LocalCounters.promotedTracks(prefs), key)) {
            return Outcome.NOT_DUE
        }
        val outcome = when {
            isInPlaylist() -> Outcome.ALREADY_IN_PLAYLIST
            add() -> Outcome.ADDED
            else -> return Outcome.NOT_ADDED
        }
        LocalCounters.markTrackPromoted(prefs, key)
        return outcome
    }

    /**
     * What an undo of the press must revert after a run that ended in
     * [outcome] against the best playlist [playlistId] (#273), whose add made
     * the playlist item [itemId] where the service names one: the promotion,
     * when this run made one, else nothing -- a track found in best already,
     * or never added, is left the way the press found it.
     */
    fun undoLeg(outcome: Outcome, playlistId: String?, itemId: String? = null): UndoLeg? =
        if (outcome == Outcome.ADDED && playlistId != null) UndoLeg.BestPromote(playlistId, itemId) else null

    /**
     * [run], then hands [journal] the run's [undoLeg], if any, against the
     * best playlist [playlistId] names once the run is over -- the Spotify
     * worker's pairing, so only the press that promoted the track leaves the
     * undo a best leg (#273, #282).
     */
    fun runJournalled(
        prefs: SharedPreferences,
        count: Int,
        threshold: Int,
        key: String,
        isInPlaylist: () -> Boolean,
        add: () -> Boolean,
        playlistId: () -> String?,
        journal: (UndoLeg) -> Unit,
    ): Outcome {
        val outcome = run(prefs, count, threshold, key, isInPlaylist, add)
        undoLeg(outcome, playlistId())?.let(journal)
        return outcome
    }
}
