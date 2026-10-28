package com.osasuwu.like_spotify

/**
 * The words on the foreground-service notification.
 *
 * Kept pure — no Android types — so the claim the notification makes can be
 * asserted in a unit test. That claim used to be unconditional ("Listening for
 * headset pattern") and was simply false without notification access: the
 * media button goes to the player, so a pause-play only ever reaches us as a
 * playback-state change seen by [PlaybackNotificationListenerService]. With the
 * grant off, the service runs, the notification said *active*, and nothing at
 * all happened (#153).
 */
object ServiceNotificationText {

    fun title(active: Boolean, listenerEnabled: Boolean): String = when {
        !listenerEnabled -> "Like Current Song is not listening"
        active -> "Like Current Song is active"
        else -> "Like Current Song is inactive"
    }

    fun body(listenerEnabled: Boolean): String = if (listenerEnabled) {
        "Listening for headset pattern"
    } else {
        "Notification access is off — pause-play cannot reach the app"
    }

    /** Label of the action that opens the grant, shown only while it is missing. */
    const val GRANT_ACTION_LABEL = "Grant access"

    /** Label of the action that undoes the last like, shown only inside its window (#269). */
    const val UNDO_ACTION_LABEL = "Undo"

    /**
     * The notification's actions, in order. Undo is appended, never slotted
     * in, so Stop and the grant keep the positions they had before it (#269).
     */
    fun actions(listenerEnabled: Boolean, undoOpen: Boolean): List<NotificationAction> = buildList {
        add(NotificationAction.STOP)
        if (!listenerEnabled) add(NotificationAction.GRANT_ACCESS)
        if (undoOpen) add(NotificationAction.UNDO)
    }
}

enum class NotificationAction { STOP, GRANT_ACCESS, UNDO }
