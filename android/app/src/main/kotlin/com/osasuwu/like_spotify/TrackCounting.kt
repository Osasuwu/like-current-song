package com.osasuwu.like_spotify

/**
 * Counts one background like on the shared Google Sheet or, failing that,
 * on this device, and journals which counter took it, so the undo (#272)
 * lowers that counter and not the other. Free of Android APIs so the choice
 * is unit-tested; the worker supplies the HTTP and prefs calls.
 *
 * The like is counted exactly once: on the Sheet when it took the count,
 * otherwise on this device. The journal write comes after the count and
 * cannot change it -- a journal that throws leaves the like counted but not
 * undoable, never counted twice.
 */
internal object TrackCounting {

    /** What counting needs. [target] and [incrementSheet] may throw; that counts as the Sheet not taking the like. */
    interface Ops {
        /** The Sheet this like counts on, or null when no counter is configured. */
        fun target(): LikeCounter.Target?

        /** Raises the track's count on [target] by one. */
        fun incrementSheet(target: LikeCounter.Target): LikeCounter.CountOutcome

        /** Raises the track's count on this device by one and answers the new count. */
        fun incrementLocal(): Int

        /** Records [leg] in the undo journal entry of this press. */
        fun journal(leg: UndoLeg.TrackCount)

        /** The Sheet answered but did not take the count; the like is being counted on this device instead. */
        fun sheetRefused(outcome: LikeCounter.CountOutcome)
    }

    /** Counts the like, journals the counter that took it, and answers the new count. */
    fun count(ops: Ops): Int {
        val onSheet = try {
            ops.target()?.let { target ->
                val outcome = ops.incrementSheet(target)
                if (outcome.count == null) ops.sheetRefused(outcome)
                outcome.count?.let { it to UndoLeg.TrackCount(target) }
            }
        } catch (e: Exception) {
            null
        }
        val (count, leg) = onSheet ?: (ops.incrementLocal() to UndoLeg.TrackCount(sheet = null))
        try {
            ops.journal(leg)
        } catch (e: Exception) {
            // Counted but not undoable: better than counted twice.
        }
        return count
    }
}
