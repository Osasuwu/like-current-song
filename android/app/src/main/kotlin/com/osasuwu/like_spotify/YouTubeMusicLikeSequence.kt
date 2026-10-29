package com.osasuwu.like_spotify

/**
 * The order a trigger's YouTube Music like runs in (#274), apart from the
 * Android pieces [YouTubeMusicJobs] fills [Steps] with: like, tone, open the
 * undo window, then count and run the extras.
 */
internal object YouTubeMusicLikeSequence {

    /** One like's steps; [O] is the like's outcome. */
    interface Steps<O> {
        fun like(): O

        fun tone(liked: O)

        /**
         * Opens the press's undo window and answers a repeat that came in
         * during the like; true when that repeat undid it. [beforeUndoLine]
         * runs before the undo writes a line, so the like's line comes first.
         */
        fun openWindow(beforeUndoLine: () -> Unit): Boolean

        /**
         * Whether a repeat or an Undo tap after the tone has been accepted.
         * Its undo is queued behind this like, so nothing has been reverted
         * yet, and work done from here would only be reverted again.
         */
        fun undoAccepted(): Boolean

        fun count(liked: O): O

        fun extras(outcome: O)

        fun logLike(outcome: O)

        fun failed(error: Exception)
    }

    fun <O> run(steps: Steps<O>) {
        // The like's own line is written before any undo line about it, even
        // when a repeat during the like undoes it before it is counted.
        var pendingLikeLine: (() -> Unit)? = null
        val beforeUndoLine = {
            pendingLikeLine?.invoke()
            pendingLikeLine = null
        }
        try {
            val liked = steps.like()
            steps.tone(liked)
            pendingLikeLine = { steps.logLike(liked) }
            // The window opens at the tone. A repeat that came in during the
            // like is answered here, and an undone like earns no counters.
            if (steps.openWindow(beforeUndoLine)) {
                beforeUndoLine()
                return
            }
            pendingLikeLine = null
            // An undo accepted after the tone is queued behind this like:
            // count and extras would cost quota and add reverts that can fail,
            // so they are skipped (Spotify runs its archive leg before the
            // window for the same reason).
            if (steps.undoAccepted()) {
                steps.logLike(liked)
                return
            }
            // After the tone: counting may take a search and an RPC, and it
            // never changes whether the like succeeded.
            val outcome = runCatching { steps.count(liked) }.getOrDefault(liked)
            steps.logLike(outcome)
            // The opt-in extras come last: they cost API quota, they can be
            // slow, and they only ever log.
            if (steps.undoAccepted()) return
            runCatching { steps.extras(outcome) }
        } catch (e: Exception) {
            steps.failed(e)
        } finally {
            // A like that threw still closes its entry: a repeat queued during
            // it is answered, and the next press likes again.
            runCatching { steps.openWindow(beforeUndoLine) }
        }
    }
}
