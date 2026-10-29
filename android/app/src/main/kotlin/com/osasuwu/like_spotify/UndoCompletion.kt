package com.osasuwu.like_spotify

import android.content.SharedPreferences

/**
 * Closing a like's [UndoJournal] entry and running its undo, reported the
 * way a Spotify undo is: the same log lines and the same tones (#274). Free
 * of Android APIs so JUnit covers it; the YouTube Music liker supplies the
 * [Report] and the [UndoRunner.Ops].
 */
internal object UndoCompletion {

    /** Where an undo says how it went. A call may throw; that is swallowed. */
    interface Report {
        /** A log line with action type `undo`; [result] is `success`, `failure` or `info`. */
        fun log(message: String, result: String, targetId: String?)

        fun tone(kind: FeedbackKind)
    }

    /**
     * Closes the like [id] at [likedAt], when its tone played: from here a
     * repeat of the trigger undoes it instead of queueing. A repeat that came
     * in during the like is answered now. Returns true when an undo ran (or
     * found nothing to revert), so the like stops: an undone like earns no
     * counters.
     */
    fun closeLike(
        prefs: SharedPreferences,
        id: String,
        likedAt: Long,
        report: Report,
        ops: () -> UndoRunner.Ops,
    ): Boolean = when (UndoJournal.finishLike(prefs, id, likedAt)) {
        UndoJournal.Finish.NONE -> false
        UndoJournal.Finish.RUN_UNDO -> {
            undo(prefs, id, report, ops)
            true
        }
        UndoJournal.Finish.UNDO_NOTHING -> {
            runCatching {
                report.log("Undo: the like had nothing to revert", "info", null)
                report.tone(FeedbackKind.UNDO)
            }
            true
        }
    }

    /**
     * Reverts every leg the like [id] journalled, newest first, and closes the
     * entry so the next press likes again. One failed leg does not stop the
     * others; the log names each one that failed. A throw is reported the
     * same way and still closes the entry.
     */
    fun undo(prefs: SharedPreferences, id: String?, report: Report, ops: () -> UndoRunner.Ops) {
        if (id == null) {
            runCatching {
                report.log("Undo skipped: no like to undo was named", "failure", null)
                report.tone(FeedbackKind.ERROR)
            }
            return
        }
        try {
            run(prefs, id, report, ops)
        } catch (t: Throwable) {
            runCatching {
                report.log("Undo failed: ${t.javaClass.simpleName}: ${t.message ?: "no message"}", "failure", null)
                report.tone(FeedbackKind.ERROR)
            }
            runCatching { UndoJournal.finishUndo(prefs, id) }
        }
    }

    private fun run(prefs: SharedPreferences, id: String, report: Report, ops: () -> UndoRunner.Ops) {
        val entry = UndoJournal.entry(prefs, id)
        if (entry == null) {
            report.log("Undo failed: the like is no longer in the journal", "failure", null)
            report.tone(FeedbackKind.ERROR)
            return
        }
        val result = UndoRunner.run(entry, ops())
        UndoJournal.finishUndo(prefs, id)
        if (result.succeeded) {
            report.log(
                "Undid like of ${entry.trackId}: " + entry.legs.joinToString { UndoRunner.legName(it) },
                "success",
                entry.trackId,
            )
            report.tone(FeedbackKind.UNDO)
        } else {
            report.log(
                "Undo failed on " + result.failures.joinToString("; ") { "${it.leg} (${it.reason})" },
                "failure",
                entry.trackId,
            )
            report.tone(FeedbackKind.ERROR)
        }
    }
}
