package com.osasuwu.like_spotify

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.view.KeyEvent
import java.lang.reflect.Method
import java.lang.reflect.Proxy

/**
 * The triple-tap mode's hold on the media keys (#158): the hidden
 * `MediaSessionManager.setOnMediaKeyListener`, reached by reflection and
 * guarded by `SET_MEDIA_KEY_LISTENER`, which only adb (or a Shizuku shell)
 * can grant.
 *
 * The system asks the listener about every media key before any player sees
 * it, and waits for the answer: past 1000 ms it dispatches the key itself. So
 * the answer comes first, from [MediaKeyCapture] over cached state, on a
 * thread of its own; a kept press reaches [onPress] on the service's main
 * thread only after the answer has gone back.
 *
 * Owned by [MediaButtonForegroundService], one instance per service start,
 * driven from its main thread: [sync] on start and on every change of the
 * mode or the grant, [close] in `onDestroy`.
 */
class TripleTapListener(
    private val context: Context,
    private val mainHandler: Handler,
    /** A kept press, on the main thread. */
    private val onPress: () -> Unit,
    /** A line for the Logs screen, on the main thread: message, result. */
    private val log: (String, String) -> Unit,
) {
    private val thread = HandlerThread("TripleTapListener").apply { start() }
    private val handler = Handler(thread.looper)
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    private val sessionManager =
        context.getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager

    /** Kept current by [deviceCallback]; read by the gate on [handler]. */
    @Volatile
    private var bluetoothOutput = false

    // Touched only on [handler]: the listener calls and the probe both run there.
    private val capture = MediaKeyCapture {
        TripleTapGate.mayCapture(bluetoothOutput, playingPackages()) {
            MusicProvider.listensTo(context, it)
        }
    }
    private val probe = SlotProbe()

    private var registered = false

    /** The hidden API is missing here; not retried within this start. */
    private var unavailable = false

    /** The failure line is written once per service start. */
    private var failureLogged = false

    private val listenerProxy: Any? by lazy {
        MediaKeyListenerApi.listenerClass?.let { listenerClass ->
            Proxy.newProxyInstance(
                TripleTapListener::class.java.classLoader,
                arrayOf(listenerClass),
            ) { proxy, method, args ->
                when (method.name) {
                    "onMediaKey" -> onMediaKey(args?.getOrNull(0) as? KeyEvent)
                    "hashCode" -> System.identityHashCode(proxy)
                    "equals" -> proxy === args?.getOrNull(0)
                    "toString" -> "TripleTapListener"
                    else -> null
                }
            }
        }
    }

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) =
            refreshOutputs()

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) =
            refreshOutputs()
    }

    private val concludeProbe = Runnable {
        val owned = probe.conclude()
        TripleTapRuntime.slotOwned = owned
        mainHandler.post {
            if (owned) {
                log("Triple tap is active: the earbuds' triple tap likes", "info")
            } else {
                log(
                    "Triple tap is on, but another app holds the media-key listener slot",
                    "failure",
                )
            }
        }
    }

    /** Brings the registration in line with the mode and the grant. Main thread. */
    fun sync(enabled: Boolean) {
        if (!enabled) {
            if (registered) unregister()
            return
        }
        if (registered || unavailable) return
        if (!isGranted(context)) {
            logFailureOnce(
                "Triple tap is on, but SET_MEDIA_KEY_LISTENER is not granted " +
                    "(adb shell pm grant ${context.packageName} $PERMISSION)",
            )
            return
        }
        register()
    }

    /** Releases the key and the thread. Main thread, from `onDestroy`. */
    fun close() {
        if (registered) unregister()
        thread.quitSafely()
    }

    private fun register() {
        val method = MediaKeyListenerApi.setMethod
        val proxy = listenerProxy
        val error = when {
            method == null || proxy == null -> MediaKeyListenerApi.lookupError
            else -> runCatching { method.invoke(sessionManager, proxy, handler) }.exceptionOrNull()
        }
        if (error != null) {
            val failure = RegistrationFailure.of(error)
            TripleTapRuntime.lastFailure = failure
            if (failure == RegistrationFailure.UNAVAILABLE) unavailable = true
            val cause = (error as? java.lang.reflect.InvocationTargetException)?.targetException ?: error
            logFailureOnce(
                "Triple tap could not take the media keys: " +
                    "${cause.javaClass.simpleName}: ${cause.message}",
            )
            return
        }
        registered = true
        capture.listening = true
        TripleTapRuntime.lastFailure = null
        TripleTapRuntime.registered = true
        TripleTapRuntime.slotOwned = null
        watchOutputs()
        startProbe()
    }

    private fun unregister() {
        // First, so a key the system still sends us from here on passes even
        // when the call below fails.
        capture.listening = false
        val error = runCatching { MediaKeyListenerApi.setMethod?.invoke(sessionManager, null, null) }
            .exceptionOrNull()
        if (error != null) {
            val cause = (error as? java.lang.reflect.InvocationTargetException)?.targetException ?: error
            log(
                "Triple tap could not hand the media keys back (${cause.javaClass.simpleName}); " +
                    "they pass to the player until the app restarts",
                "info",
            )
        }
        runCatching { audioManager?.unregisterAudioDeviceCallback(deviceCallback) }
        handler.removeCallbacks(concludeProbe)
        registered = false
        TripleTapRuntime.registered = false
        TripleTapRuntime.slotOwned = null
    }

    /**
     * Sends a `RECORD` pair to the system and sees whether this listener gets
     * it: a registration while another app holds the slot is ignored without
     * an error, so this is the only way to know. Only on a registration, never
     * per command.
     */
    private fun startProbe() {
        handler.post {
            handler.removeCallbacks(concludeProbe)
            val time = SystemClock.uptimeMillis()
            probe.begin(time)
            runCatching {
                audioManager?.dispatchMediaKeyEvent(
                    KeyEvent(time, time, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_RECORD, 0),
                )
                audioManager?.dispatchMediaKeyEvent(
                    KeyEvent(time, time, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MEDIA_RECORD, 0),
                )
            }
            handler.postDelayed(concludeProbe, PROBE_MS)
        }
    }

    /** The listener's answer: true keeps the key from the player. On [handler]. */
    private fun onMediaKey(event: KeyEvent?): Boolean {
        if (event == null) return false
        if (probe.claims(event.keyCode, event.eventTime)) return true
        return when (capture.onKey(event.keyCode, event.action, event.repeatCount)) {
            MediaKeyCapture.Answer.PASS -> false
            MediaKeyCapture.Answer.CONSUME -> true
            MediaKeyCapture.Answer.PRESS -> {
                // The answer goes back in the message that is running now; this
                // posts behind it, so the like starts only once it has gone.
                handler.post { mainHandler.post(onPress) }
                true
            }
        }
    }

    /** Packages of the `STATE_PLAYING` sessions; null without notification access. */
    private fun playingPackages(): List<String>? {
        val manager = sessionManager ?: return null
        return try {
            manager.getActiveSessions(
                ComponentName(context, PlaybackNotificationListenerService::class.java),
            )
                .filter { it.playbackState?.state == PlaybackState.STATE_PLAYING }
                .map { it.packageName }
        } catch (e: Exception) {
            null
        }
    }

    private fun watchOutputs() {
        refreshOutputs()
        runCatching { audioManager?.registerAudioDeviceCallback(deviceCallback, handler) }
    }

    private fun refreshOutputs() {
        bluetoothOutput = bluetoothOutputConnected(context)
    }

    private fun logFailureOnce(message: String) {
        if (failureLogged) return
        failureLogged = true
        log(message, "failure")
    }

    companion object {
        const val PERMISSION = "android.permission.SET_MEDIA_KEY_LISTENER"
        private const val PROBE_MS = 500L

        fun isGranted(context: Context): Boolean =
            context.checkSelfPermission(PERMISSION) == PackageManager.PERMISSION_GRANTED

        fun bluetoothOutputConnected(context: Context): Boolean {
            val manager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return false
            return runCatching {
                manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                    .any { BluetoothAudioOutput.counts(it.type) }
            }.getOrDefault(false)
        }

        /** The line the trigger config screen shows, read live. */
        fun status(context: Context): TripleTapStatus {
            val prefs = context.getSharedPreferences(AppConstants.PREFS, Context.MODE_PRIVATE)
            val failure = TripleTapRuntime.lastFailure
            return TripleTapStatus.of(
                enabled = prefs.getBoolean(AppConstants.KEY_TRIPLE_TAP_ENABLED, false),
                apiAvailable = MediaKeyListenerApi.setMethod != null &&
                    failure != RegistrationFailure.UNAVAILABLE,
                granted = isGranted(context) && failure != RegistrationFailure.NOT_GRANTED,
                notificationAccess = PlaybackNotificationListenerService.isEnabled(context),
                listenerRunning = TripleTapRuntime.registered,
                slotOwned = TripleTapRuntime.slotOwned,
                bluetoothOutput = bluetoothOutputConnected(context),
            )
        }
    }
}

/**
 * What the running listener knows, for [TripleTapListener.status] to read
 * from the activity. Process-wide: the service and the activity share it.
 */
object TripleTapRuntime {
    @Volatile
    var registered = false

    /** The last registration's failure; cleared by a registration that works. */
    @Volatile
    var lastFailure: RegistrationFailure? = null

    /** The probe's verdict; null while unprobed or unregistered. */
    @Volatile
    var slotOwned: Boolean? = null
}

/**
 * The hidden API, looked up once. Null members mean this build lacks it.
 * Reflection on purpose (lint's PrivateApi): the API is `@SystemApi`, and
 * every failure here degrades to the "unavailable" status, never a crash.
 */
@SuppressLint("PrivateApi")
private object MediaKeyListenerApi {
    private val lookup: Result<Pair<Class<*>, Method>> by lazy {
        runCatching {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                throw NoSuchMethodException("setOnMediaKeyListener needs Android 8.0")
            }
            val listener =
                Class.forName("android.media.session.MediaSessionManager\$OnMediaKeyListener")
            listener to MediaSessionManager::class.java.getMethod(
                "setOnMediaKeyListener",
                listener,
                Handler::class.java,
            )
        }
    }

    val listenerClass: Class<*>? get() = lookup.getOrNull()?.first
    val setMethod: Method? get() = lookup.getOrNull()?.second
    val lookupError: Throwable? get() = lookup.exceptionOrNull()
}
