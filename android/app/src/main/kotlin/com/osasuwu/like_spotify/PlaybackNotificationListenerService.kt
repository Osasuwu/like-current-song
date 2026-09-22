package com.osasuwu.like_spotify

import android.content.ComponentName
import android.content.Context
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import androidx.core.app.NotificationManagerCompat

class PlaybackNotificationListenerService : NotificationListenerService() {
    private lateinit var mediaSessionManager: MediaSessionManager
    private val callbacks = mutableMapOf<String, MediaController.Callback>()
    private val lastStateByPackage = mutableMapOf<String, Int>()

    private val activeSessionsChangedListener = MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
        attachControllers(controllers ?: emptyList())
    }

    override fun onCreate() {
        super.onCreate()
        mediaSessionManager = getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        log("Notification listener connected")
        MediaButtonForegroundService.notifyListenerStateChanged(this)
        mediaSessionManager.addOnActiveSessionsChangedListener(
            activeSessionsChangedListener,
            ComponentName(this, PlaybackNotificationListenerService::class.java)
        )
        refreshSessions()
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        // Access was revoked (or the binding dropped): the foreground service
        // is now listening for nothing and must stop saying otherwise.
        MediaButtonForegroundService.notifyListenerStateChanged(this)
        runCatching {
            mediaSessionManager.removeOnActiveSessionsChangedListener(activeSessionsChangedListener)
        }
        callbacks.forEach { (token, callback) ->
            runCatching {
                val controller = mediaSessionManager.getActiveSessions(
                    ComponentName(this, PlaybackNotificationListenerService::class.java)
                ).find { it.sessionToken.toString() == token }
                controller?.unregisterCallback(callback)
            }
        }
        callbacks.clear()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        super.onNotificationPosted(sbn)
        refreshSessions()
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        super.onNotificationRemoved(sbn)
        refreshSessions()
    }

    private fun refreshSessions() {
        val component = ComponentName(this, PlaybackNotificationListenerService::class.java)
        val controllers = runCatching { mediaSessionManager.getActiveSessions(component) }
            .getOrDefault(emptyList())
        attachControllers(controllers)
    }

    private fun attachControllers(controllers: List<MediaController>) {
        val byToken = controllers.associateBy { it.sessionToken.toString() }

        val toRemove = callbacks.keys.filter { it !in byToken.keys }
        toRemove.forEach { token ->
            val callback = callbacks.remove(token) ?: return@forEach
            byToken[token]?.unregisterCallback(callback)
        }

        controllers.forEach { controller ->
            val token = controller.sessionToken.toString()
            if (callbacks.containsKey(token)) {
                return@forEach
            }

            val callback = object : MediaController.Callback() {
                override fun onPlaybackStateChanged(state: android.media.session.PlaybackState?) {
                    val packageName = controller.packageName ?: return
                    val rawState = state?.state ?: return

                    val mapped = when (rawState) {
                        android.media.session.PlaybackState.STATE_PLAYING -> "play"
                        android.media.session.PlaybackState.STATE_PAUSED,
                        android.media.session.PlaybackState.STATE_STOPPED,
                        android.media.session.PlaybackState.STATE_NONE -> "pause"
                        else -> null
                    } ?: return

                    val previous = lastStateByPackage[packageName]
                    if (previous == rawState) {
                        return
                    }
                    lastStateByPackage[packageName] = rawState

                    val service = this@PlaybackNotificationListenerService
                    // Remembered even for a service the trigger ignores: it is
                    // what automatic routing falls back to once playback stops.
                    if (rawState == android.media.session.PlaybackState.STATE_PLAYING) {
                        MusicProvider.values()
                            .firstOrNull { it.ownsSession(packageName) }
                            ?.let { MusicProvider.recordPlaying(service, it) }
                    }

                    if (MusicProvider.listensTo(service, packageName)) {
                        log("Playback state from $packageName: $mapped")
                        MediaButtonForegroundService.dispatchExternalMediaEvent(service, mapped)
                    }
                }
            }

            controller.registerCallback(callback)
            callbacks[token] = callback
        }
    }

    private fun log(message: String, actionType: String = "notification_listener", result: String = "info") {
        BackgroundLog.emit(this, message, actionType, result)
        val intent = android.content.Intent(AppConstants.ACTION_LOG_EVENT)
            .putExtra(AppConstants.EXTRA_LOG, message)
            .putExtra(AppConstants.EXTRA_LOG_ACTION_TYPE, actionType)
            .putExtra(AppConstants.EXTRA_LOG_RESULT, result)
        androidx.localbroadcastmanager.content.LocalBroadcastManager
            .getInstance(this)
            .sendBroadcast(intent)
    }

    companion object {
        fun isEnabled(context: Context): Boolean {
            return NotificationManagerCompat
                .getEnabledListenerPackages(context)
                .contains(context.packageName)
        }
    }
}
