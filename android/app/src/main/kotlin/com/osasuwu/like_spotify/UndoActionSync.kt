package com.osasuwu.like_spotify

import android.content.SharedPreferences

/**
 * The service's decisions about the notification's Undo action (#269),
 * kept apart from [MediaButtonForegroundService] so they can be tested
 * without Android. The journal says what may be undone; this says what the
 * notification does about it.
 */
object UndoActionSync {

    /**
     * What a sync does next. [repost]: rebuild the notification. [offer]: the
     * like the action is offered for afterwards, null for none. [recheckInMs]:
     * when to look again, null for never.
     */
    data class Plan(val repost: Boolean, val offer: String?, val recheckInMs: Long?)

    /**
     * The sync for [window], the journal's answer at [now], while the
     * notification offers [shown]. [halted]: the user stopped the service or
     * it is being destroyed; nothing may be posted or re-armed then.
     */
    fun next(window: UndoJournal.Window?, shown: String?, now: Long, halted: Boolean): Plan {
        if (halted) return Plan(repost = false, offer = shown, recheckInMs = null)
        val offer = window?.pressId
        return Plan(
            repost = offer != shown,
            offer = offer,
            // Just past the close: the window is open on its last millisecond.
            recheckInMs = window?.let { it.closesAt - now + 1 },
        )
    }

    /** What a tap on the action comes to; see [tap]. */
    enum class Tap {
        /** The tap started the undo: run the undo job. */
        UNDO,

        /** An undo of that like is already under way: stay silent, as a repeat press does. */
        ALREADY_UNDOING,

        /** The window passed or a newer like took it over: nothing undone, and the user hears so. */
        TOO_LATE,
    }

    /**
     * A tap the journal [accepted] or refused; [tappedState] is the tapped
     * like's state after the attempt, null when the journal no longer has it.
     */
    fun tap(accepted: Boolean, tappedState: UndoJournal.State?): Tap = when {
        accepted -> Tap.UNDO
        tappedState == UndoJournal.State.UNDOING -> Tap.ALREADY_UNDOING
        else -> Tap.TOO_LATE
    }

    /**
     * A tap on an Undo control offered for [pressId] at [now]: the
     * notification action (#269) or the in-app button (#268). Asks the
     * journal to start the undo, then calls [startUndo] with the like's id
     * when it did, or [tooLate] when the like can no longer be undone. A tap on
     * an undo already under way calls neither, as a repeat press stays silent.
     */
    fun tap(
        prefs: SharedPreferences,
        pressId: String?,
        now: Long,
        startUndo: (String) -> Unit,
        tooLate: () -> Unit,
    ): Tap {
        val accepted = pressId != null && UndoJournal.requestUndo(prefs, pressId, now)
        val tappedState = pressId?.let { UndoJournal.entry(prefs, it)?.state }
        val result = tap(accepted, tappedState)
        when (result) {
            Tap.UNDO -> startUndo(pressId!!)
            Tap.ALREADY_UNDOING -> Unit
            Tap.TOO_LATE -> tooLate()
        }
        return result
    }

    /**
     * [window] as the platform channel carries it to Dart (#268): `pressId`
     * and `closesAt` (epoch ms, inclusive); null when no window is open.
     */
    fun channelMap(window: UndoJournal.Window?): Map<String, Any>? =
        window?.let { mapOf("pressId" to it.pressId, "closesAt" to it.closesAt) }
}
