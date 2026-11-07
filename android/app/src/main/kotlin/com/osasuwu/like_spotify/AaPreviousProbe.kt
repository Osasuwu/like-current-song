package com.osasuwu.like_spotify

import android.app.UiModeManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * SPIKE, not for merge: records what a player's MediaSession reports when
 * Android Auto sends it "previous", so a detect-and-revert trigger can be
 * designed against real data instead of guesses.
 *
 * Android Auto drives the player through its MediaController, never through a
 * media key, so [TripleTapListener] never sees it. What we can see is the
 * aftermath: every playback state and metadata change of every active session.
 *
 * Output: logcat tag [TAG] and the file
 * `/sdcard/Android/data/com.osasuwu.like_spotify/files/aa-probe.log`
 * (`adb pull` it after a drive). Each line carries the car-mode flag, so the
 * drive's lines can be told from the phone's.
 */
class AaPreviousProbe(private val context: Context) {

    private val thread = HandlerThread("AaPreviousProbe").apply { start() }
    private val handler = Handler(thread.looper)
    private val sessionManager =
        context.getSystemService(Context.MEDIA_SESSION_SERVICE) as? MediaSessionManager
    private val uiMode = context.getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
    private val component = ComponentName(context, PlaybackNotificationListenerService::class.java)
    private val file: File? = context.getExternalFilesDir(null)?.let { File(it, FILE_NAME) }
    private val clock = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    /** Touched only on [handler]. */
    private val watched = HashMap<MediaSession.Token, Pair<MediaController, MediaController.Callback>>()

    private val sessionsListener =
        MediaSessionManager.OnActiveSessionsChangedListener { controllers -> attach(controllers.orEmpty()) }

    private val carModeReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, intent: Intent?) {
            handler.post { write("system", "broadcast ${intent?.action}") }
        }
    }

    fun start() {
        handler.post {
            write("probe", "start sdk=${Build.VERSION.SDK_INT} model=${Build.MODEL}")
            val manager = sessionManager
            if (manager == null) {
                write("probe", "no MediaSessionManager")
                return@post
            }
            try {
                manager.addOnActiveSessionsChangedListener(sessionsListener, component, handler)
                attach(manager.getActiveSessions(component))
            } catch (e: SecurityException) {
                write("probe", "no notification access: ${e.message}")
            }
        }
        val filter = IntentFilter().apply {
            addAction(UiModeManager.ACTION_ENTER_CAR_MODE)
            addAction(UiModeManager.ACTION_EXIT_CAR_MODE)
        }
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(carModeReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                context.registerReceiver(carModeReceiver, filter)
            }
        }
    }

    fun close() {
        runCatching { context.unregisterReceiver(carModeReceiver) }
        handler.post {
            runCatching { sessionManager?.removeOnActiveSessionsChangedListener(sessionsListener) }
            watched.values.forEach { (controller, callback) -> controller.unregisterCallback(callback) }
            watched.clear()
            write("probe", "stop")
            thread.quitSafely()
        }
    }

    private fun attach(controllers: List<MediaController>) {
        val live = controllers.associateBy { it.sessionToken }
        watched.keys.filter { it !in live }.forEach { token ->
            watched.remove(token)?.let { (controller, callback) ->
                controller.unregisterCallback(callback)
                write(controller.packageName, "session gone")
            }
        }
        live.forEach { (token, controller) ->
            if (token in watched) return@forEach
            val callback = callbackFor(controller)
            controller.registerCallback(callback, handler)
            watched[token] = controller to callback
            write(controller.packageName, "session attached")
            write(controller.packageName, "  meta  ${describe(controller.metadata)}")
            write(controller.packageName, "  state ${describe(controller.playbackState)}")
        }
    }

    private fun callbackFor(controller: MediaController) = object : MediaController.Callback() {
        val pkg: String = controller.packageName

        override fun onPlaybackStateChanged(state: PlaybackState?) =
            write(pkg, "state ${describe(state)}")

        override fun onMetadataChanged(metadata: MediaMetadata?) =
            write(pkg, "meta  ${describe(metadata)}")

        override fun onSessionEvent(event: String, extras: Bundle?) =
            write(pkg, "event $event ${extras?.keySet()}")

        override fun onQueueChanged(queue: MutableList<MediaSession.QueueItem>?) =
            write(pkg, "queue size=${queue?.size}")

        override fun onExtrasChanged(extras: Bundle?) =
            write(pkg, "extras ${extras?.keySet()}")

        override fun onSessionDestroyed() = write(pkg, "destroyed")
    }

    private fun describe(state: PlaybackState?): String {
        if (state == null) return "null"
        val now = SystemClock.elapsedRealtime()
        val projected = if (state.state == PlaybackState.STATE_PLAYING) {
            state.position + ((now - state.lastPositionUpdateTime) * state.playbackSpeed).toLong()
        } else {
            state.position
        }
        val custom = state.customActions.joinToString(",") { it.action }
        return "${stateName(state.state)} pos=${state.position} projected=$projected " +
            "updated=${now - state.lastPositionUpdateTime}ms_ago speed=${state.playbackSpeed} " +
            "queueId=${state.activeQueueItemId} actions=0x${state.actions.toString(16)} " +
            "custom=[$custom] err=${state.errorMessage}"
    }

    private fun describe(metadata: MediaMetadata?): String {
        if (metadata == null) return "null"
        return "\"${metadata.getString(MediaMetadata.METADATA_KEY_TITLE)}\" / " +
            "${metadata.getString(MediaMetadata.METADATA_KEY_ARTIST)} " +
            "dur=${metadata.getLong(MediaMetadata.METADATA_KEY_DURATION)} " +
            "id=${metadata.getString(MediaMetadata.METADATA_KEY_MEDIA_ID)}"
    }

    private fun stateName(state: Int) = when (state) {
        PlaybackState.STATE_NONE -> "NONE"
        PlaybackState.STATE_STOPPED -> "STOPPED"
        PlaybackState.STATE_PAUSED -> "PAUSED"
        PlaybackState.STATE_PLAYING -> "PLAYING"
        PlaybackState.STATE_FAST_FORWARDING -> "FF"
        PlaybackState.STATE_REWINDING -> "REWIND"
        PlaybackState.STATE_BUFFERING -> "BUFFERING"
        PlaybackState.STATE_ERROR -> "ERROR"
        PlaybackState.STATE_CONNECTING -> "CONNECTING"
        PlaybackState.STATE_SKIPPING_TO_PREVIOUS -> "SKIP_PREV"
        PlaybackState.STATE_SKIPPING_TO_NEXT -> "SKIP_NEXT"
        PlaybackState.STATE_SKIPPING_TO_QUEUE_ITEM -> "SKIP_QUEUE"
        else -> "?$state"
    }

    private fun carMode(): Boolean =
        uiMode?.currentModeType == Configuration.UI_MODE_TYPE_CAR

    /** On [handler]. */
    private fun write(source: String, message: String) {
        val line = "${clock.format(Date())} rt=${SystemClock.elapsedRealtime()} " +
            "car=${carMode()} [$source] $message"
        Log.i(TAG, line)
        val target = file ?: return
        runCatching {
            if (target.length() > MAX_BYTES) {
                target.renameTo(File(target.parentFile, "$FILE_NAME.1"))
            }
            target.appendText(line + "\n")
        }
    }

    companion object {
        const val TAG = "LcsAaProbe"
        private const val FILE_NAME = "aa-probe.log"
        private const val MAX_BYTES = 4L * 1024 * 1024
    }
}
