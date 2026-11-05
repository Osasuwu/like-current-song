package com.osasuwu.like_spotify

import android.annotation.SuppressLint
import android.media.AudioDeviceInfo
import android.view.KeyEvent

/**
 * When the triple-tap mode (#158) may keep a `PREVIOUS` press for a like
 * instead of letting the player skip back.
 *
 * Every refusal is a fail-safe: a press the gate refuses is an ordinary
 * previous, so the cost of a wrong "no" is a skip-back the user asked for
 * anyway, and the cost of a wrong "yes" is a like nobody asked for.
 */
object TripleTapGate {
    /**
     * [bluetoothOutput]: a Bluetooth audio output is connected (the earbuds'
     * triple tap is the gesture; the phone's own controls are not).
     * [playingPackages]: the packages of the `STATE_PLAYING` sessions, or
     * null when notification access is missing and they cannot be read
     * (the #248 fail-safe: without it the like cannot tell what is playing).
     * [listensTo]: whether a like listens to that package's sessions
     * ([MusicProvider.listensTo]); a podcast or a video playing means the
     * user wants its previous, not a like.
     */
    fun mayCapture(
        bluetoothOutput: Boolean,
        playingPackages: List<String>?,
        listensTo: (String) -> Boolean,
    ): Boolean {
        if (!bluetoothOutput) return false
        if (playingPackages == null) return false
        return playingPackages.all(listensTo)
    }
}

/**
 * The listener's answer for each media key. The system waits for it
 * synchronously and dispatches the key itself after 1000 ms, so the gate
 * may read only what is cached or one quick binder call away (the active
 * sessions) — no network, no disk.
 *
 * Only `PREVIOUS` is ever kept. Its `DOWN` (repeat 0) asks [mayCapture] once;
 * the `UP` and any repeats of that press follow the `DOWN`'s answer, so a
 * player never sees half a press. The pairing is a flag rather than a
 * `downTime` match because Bluetooth AVRCP keys arrive with `downTime` 0.
 *
 * Not thread-safe: the service calls it from its one listener thread.
 */
class MediaKeyCapture(private val mayCapture: () -> Boolean) {
    enum class Answer {
        /** Not handled: the system gives the key to the player. */
        PASS,

        /** Handled, nothing to do: the rest of a press already taken. */
        CONSUME,

        /** Handled, and one press for the like pipeline. */
        PRESS,
    }

    private var holdingPress = false

    /**
     * Whether the mode wants the keys now. The system may go on calling a
     * listener the service has let go of: `setOnMediaKeyListener(null)` needs
     * the same grant, so after a revoke it fails and the old registration
     * stays until the process dies. While false every key passes. Set from
     * the main thread, read on the listener's.
     */
    @Volatile
    var listening = false

    fun onKey(keyCode: Int, action: Int, repeatCount: Int): Answer {
        if (!listening) {
            holdingPress = false
            return Answer.PASS
        }
        if (keyCode != KeyEvent.KEYCODE_MEDIA_PREVIOUS) return Answer.PASS
        return when (action) {
            KeyEvent.ACTION_DOWN ->
                if (repeatCount == 0) {
                    holdingPress = mayCapture()
                    if (holdingPress) Answer.PRESS else Answer.PASS
                } else {
                    if (holdingPress) Answer.CONSUME else Answer.PASS
                }
            KeyEvent.ACTION_UP ->
                if (holdingPress) {
                    holdingPress = false
                    Answer.CONSUME
                } else {
                    Answer.PASS
                }
            else -> Answer.PASS
        }
    }
}


/**
 * Whether the listener slot is really ours. The system keeps one media-key
 * listener; registering while another app holds it is silently ignored, so
 * the service sends itself a `RECORD` `DOWN`+`UP` pair stamped with a unique
 * `eventTime` and sees whether its own listener receives it.
 *
 * The keys stay claimed after [conclude], so a pair that arrives late is
 * still consumed rather than handed to the player. Same thread as the
 * listener.
 */
class SlotProbe {
    private var token: Long? = null
    private var seen = false

    /** Starts a probe for the pair sent with [eventTime]. */
    fun begin(eventTime: Long) {
        token = eventTime
        seen = false
    }

    /** True when the key is the probe's own, which the listener then consumes. */
    fun claims(keyCode: Int, eventTime: Long): Boolean {
        if (keyCode != KeyEvent.KEYCODE_MEDIA_RECORD || eventTime != token) return false
        seen = true
        return true
    }

    /** Whether the probe came back to this listener. */
    fun conclude(): Boolean = seen
}

/**
 * The one line the trigger config screen shows for the mode. [wire] is the
 * name it crosses the method channel as; the Dart side parses it.
 */
enum class TripleTapStatus(val wire: String) {
    OFF("off"),
    UNAVAILABLE("unavailable"),
    NOT_GRANTED("not_granted"),
    NEEDS_NOTIFICATION_ACCESS("needs_notification_access"),
    LISTENER_OFF("listener_off"),
    SLOT_TAKEN("slot_taken"),
    NO_BLUETOOTH_OUTPUT("no_bluetooth_output"),
    ACTIVE("active"),
    ;

    companion object {
        /**
         * The first thing in the way, in the order the user can fix them: a
         * mode that is off says nothing else, a missing API cannot be granted
         * around, and a Bluetooth output is the last thing worth asking for.
         * [listenerRunning]: the foreground service that holds the listener
         * is up; without it nothing listens, whatever else is in place.
         * [slotOwned] null is a slot not probed yet (the probe in flight):
         * not reported as taken.
         */
        fun of(
            enabled: Boolean,
            apiAvailable: Boolean,
            granted: Boolean,
            notificationAccess: Boolean,
            listenerRunning: Boolean,
            slotOwned: Boolean?,
            bluetoothOutput: Boolean,
        ): TripleTapStatus = when {
            !enabled -> OFF
            !apiAvailable -> UNAVAILABLE
            !granted -> NOT_GRANTED
            !notificationAccess -> NEEDS_NOTIFICATION_ACCESS
            !listenerRunning -> LISTENER_OFF
            slotOwned == false -> SLOT_TAKEN
            !bluetoothOutput -> NO_BLUETOOTH_OUTPUT
            else -> ACTIVE
        }
    }
}

/**
 * Which audio outputs make a triple tap the earbuds' gesture. Media-audio
 * Bluetooth only: classic A2DP, hearing aids and LE Audio. `SCO` is a call
 * link, and the phone's own speaker or a wired headset has no triple tap.
 * Older systems never report the newer types, so no SDK check is needed.
 */
object BluetoothAudioOutput {
    @SuppressLint("InlinedApi")
    private val TYPES = setOf(
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_HEARING_AID,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLE_SPEAKER,
        AudioDeviceInfo.TYPE_BLE_BROADCAST,
    )

    fun counts(type: Int): Boolean = type in TYPES
}

/** What a failed reflective registration means for the status. */
enum class RegistrationFailure {
    /** `SET_MEDIA_KEY_LISTENER` is not granted: the adb command fixes it. */
    NOT_GRANTED,

    /** The hidden API is missing or changed on this Android build. */
    UNAVAILABLE,
    ;

    companion object {
        fun of(error: Throwable): RegistrationFailure {
            val cause = if (error is java.lang.reflect.InvocationTargetException) error.targetException else error
            return if (cause is SecurityException) NOT_GRANTED else UNAVAILABLE
        }
    }
}
