package com.osasuwu.like_spotify

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
}
