package com.osasuwu.like_spotify

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import android.view.KeyEvent
import android.support.v4.media.session.MediaSessionCompat
import androidx.core.app.NotificationCompat
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MediaButtonForegroundService : Service() {
    private lateinit var mediaSession: MediaSessionCompat
    private lateinit var detector: MediaEventPatternDetector
    private var nextToggleIsPause = true
    private var stoppedByUser = false

    /** Runs YouTube Music likes (binder polling + HTTP) off the main thread. */
    private val likeExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()

        detector = MediaEventPatternDetector(
            windowMsProvider = { prefs().getLong(AppConstants.KEY_WINDOW_MS, 1000L) },
            debounceMsProvider = { prefs().getLong(AppConstants.KEY_DEBOUNCE_MS, 650L) },
            patternProvider = { loadPattern() }
        )

        mediaSession = MediaSessionCompat(this, "LikeSpotifySession").apply {
            setFlags(
                MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS
            )
            val mediaButtonIntent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
                setClass(this@MediaButtonForegroundService, MediaButtonReceiver::class.java)
            }
            val mediaButtonPendingIntent = PendingIntent.getBroadcast(
                this@MediaButtonForegroundService,
                4,
                mediaButtonIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            setMediaButtonReceiver(mediaButtonPendingIntent)
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() {
                    onMediaEvent("play")
                }

                override fun onPause() {
                    onMediaEvent("pause")
                }
            })
            isActive = true
        }

        startForeground(AppConstants.NOTIFICATION_ID, buildNotification(active = true))
        sendServiceState(true)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> stopSelfSafely()
            ACTION_EXTERNAL_MEDIA_EVENT -> {
                val rawEvent = intent.getStringExtra(AppConstants.EXTRA_EVENT)
                val event = normalizeExternalEvent(rawEvent)
                if (event != null) {
                    log("External media event: $rawEvent -> $event")
                    onMediaEvent(event)
                }
            }
            ACTION_START, null -> {
                startForeground(AppConstants.NOTIFICATION_ID, buildNotification(active = true))
                sendServiceState(true)
            }
        }
        return START_STICKY
    }

    /**
     * The user swiped the app out of recents. Stock Android keeps a foreground
     * service alive through that, but some OEM shells (MIUI / HyperOS) tear the
     * service down with the task. Re-assert foreground state and queue a restart
     * so listening survives either way.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        if (stoppedByUser || !prefs().getBoolean(AppConstants.KEY_SERVICE_ENABLED, false)) {
            return
        }
        log("Task removed from recents — keeping service alive")
        runCatching {
            startForeground(AppConstants.NOTIFICATION_ID, buildNotification(active = true))
        }
        scheduleRestart()
    }

    override fun onDestroy() {
        likeExecutor.shutdown()
        mediaSession.isActive = false
        mediaSession.release()
        if (stoppedByUser) {
            sendServiceState(false)
        } else {
            // Killed by the system, not switched off: keep the persisted "enabled"
            // flag so the boot receiver and the queued restart can bring it back.
            broadcastServiceState(false)
            scheduleRestart()
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun onMediaEvent(event: String) {
        broadcastMediaEvent(event)
        if (detector.onEvent(event, System.currentTimeMillis())) {
            log("Trigger matched: ${loadPattern().joinToString(" -> ")}")
            if (MainActivity.isFlutterAttached) {
                log("Delegating to Flutter (full workflow)")
                val intent = Intent(AppConstants.ACTION_TRIGGER_LIKE)
                LocalBroadcastManager.getInstance(this).sendBroadcast(intent)
            } else {
                likeInBackground()
            }
        }
    }

    /**
     * Likes without Flutter: Spotify via WorkManager, YouTube Music in-process.
     *
     * The service is resolved here rather than in Dart because this is the
     * path the trigger normally takes — the engine is usually detached when
     * the pattern fires. [MusicProvider.resolve] is the same rule Dart runs.
     */
    private fun likeInBackground() {
        val routing = MusicProvider.resolve(this)
        if (routing.automatic) {
            log(routing.logLine(), actionType = "music_routing")
        }
        when (routing.provider) {
            MusicProvider.SPOTIFY -> {
                log("Flutter not attached — using WorkManager fallback")
                SpotifyLikeWorker.enqueue(this, routing.provider)
            }
            MusicProvider.YTMUSIC -> likeYouTubeMusicInBackground()
        }
    }

    /**
     * The session like needs a live MediaController, which a WorkManager job
     * can't carry, so it runs on [likeExecutor] under a partial wake lock (the
     * screen is usually off when the trigger fires).
     */
    private fun likeYouTubeMusicInBackground() {
        val appContext = applicationContext
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        val wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "LikeSpotify:ytmusic-like")
        wakeLock.setReferenceCounted(false)
        wakeLock.acquire(YTM_LIKE_WAKE_LOCK_MS)
        val submitted = runCatching {
            likeExecutor.execute {
                try {
                    val liker = YouTubeMusicLiker(appContext)
                    val liked = liker.like()
                    FeedbackPlayer.play(appContext, liked.positive)
                    // After the tone: counting may take a search and an RPC,
                    // and it never changes whether the like succeeded.
                    val outcome = runCatching { liker.count(liked) }.getOrDefault(liked)
                    log(
                        outcome.logLine(),
                        actionType = "like_track",
                        result = if (outcome.positive) "success" else "failure",
                    )
                    // The opt-in extras come last: they cost API quota, they
                    // can be slow, and they only ever log.
                    runCatching { liker.extraActions(outcome) }
                } catch (e: Exception) {
                    FeedbackPlayer.play(appContext, false)
                    log("YouTube Music like failed: ${e.message}", actionType = "like_track", result = "failure")
                } finally {
                    if (wakeLock.isHeld) wakeLock.release()
                }
            }
        }
        if (submitted.isFailure && wakeLock.isHeld) wakeLock.release()
    }

    private fun normalizeExternalEvent(event: String?): String? {
        return when (event) {
            "play" -> "play"
            "pause" -> "pause"
            "toggle" -> {
                val mapped = if (nextToggleIsPause) "pause" else "play"
                nextToggleIsPause = !nextToggleIsPause
                mapped
            }
            else -> null
        }
    }

    private fun broadcastMediaEvent(event: String) {
        val intent = Intent(AppConstants.ACTION_MEDIA_EVENT).putExtra(AppConstants.EXTRA_EVENT, event)
        LocalBroadcastManager.getInstance(this).sendBroadcast(intent)
    }

    private fun sendServiceState(active: Boolean) {
        prefs().edit().putBoolean(AppConstants.KEY_SERVICE_ENABLED, active).apply()
        broadcastServiceState(active)
    }

    private fun broadcastServiceState(active: Boolean) {
        val intent = Intent(AppConstants.ACTION_SERVICE_STATE).putExtra(AppConstants.EXTRA_ACTIVE, active)
        LocalBroadcastManager.getInstance(this).sendBroadcast(intent)
    }

    private fun loadPattern(): List<String> {
        val raw = prefs().getString(AppConstants.KEY_PATTERN, "pause,play") ?: "pause,play"
        return raw.split(',').map { it.trim() }.filter { it.isNotEmpty() }
    }

    private fun log(message: String, actionType: String = "media_event", result: String = "info") {
        val intent = Intent(AppConstants.ACTION_LOG_EVENT)
            .putExtra(AppConstants.EXTRA_LOG, message)
            .putExtra(AppConstants.EXTRA_LOG_ACTION_TYPE, actionType)
            .putExtra(AppConstants.EXTRA_LOG_RESULT, result)
        LocalBroadcastManager.getInstance(this).sendBroadcast(intent)
    }

    private fun buildNotification(active: Boolean): Notification {
        val stopIntent = Intent(this, MediaButtonForegroundService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            2,
            stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
        val openPendingIntent = PendingIntent.getActivity(
            this,
            3,
            openIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, AppConstants.NOTIFICATION_CHANNEL_ID)
            .setContentTitle("Like Current Song is ${if (active) "active" else "inactive"}")
            .setContentText("Listening for headset pattern")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .setSilent(true)
            .addAction(0, "Stop", stopPendingIntent)
            .setContentIntent(openPendingIntent)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val channel = NotificationChannel(
            AppConstants.NOTIFICATION_CHANNEL_ID,
            AppConstants.NOTIFICATION_CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW
        )
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)
    }

    /**
     * Queues a one-shot start of this service about a second from now. If the
     * service is still alive the start is a no-op re-assert; if the OEM killed it,
     * this brings it back. Starting a foreground service from the background is
     * only permitted on Android 12+ when the app is exempt from battery
     * optimisation, so a refused start fails inside the system, not here.
     */
    private fun scheduleRestart() {
        val alarmManager = getSystemService(AlarmManager::class.java) ?: return
        runCatching {
            alarmManager.set(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + RESTART_DELAY_MS,
                restartPendingIntent()
            )
        }
    }

    private fun cancelScheduledRestart() {
        val alarmManager = getSystemService(AlarmManager::class.java) ?: return
        runCatching { alarmManager.cancel(restartPendingIntent()) }
    }

    private fun restartPendingIntent(): PendingIntent {
        val restartIntent = Intent(applicationContext, MediaButtonForegroundService::class.java).apply {
            action = ACTION_START
        }
        val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            PendingIntent.getForegroundService(applicationContext, RESTART_REQUEST_CODE, restartIntent, flags)
        } else {
            PendingIntent.getService(applicationContext, RESTART_REQUEST_CODE, restartIntent, flags)
        }
    }

    private fun stopSelfSafely() {
        stoppedByUser = true
        cancelScheduledRestart()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun prefs() = getSharedPreferences(AppConstants.PREFS, Context.MODE_PRIVATE)

    companion object {
        const val ACTION_START = "ACTION_START"
        const val ACTION_STOP = "ACTION_STOP"
        const val ACTION_EXTERNAL_MEDIA_EVENT = "ACTION_EXTERNAL_MEDIA_EVENT"
        private const val TAG = "LikeSpotifyService"
        private const val RESTART_REQUEST_CODE = 5
        private const val RESTART_DELAY_MS = 1000L

        /** Session confirm (~2 s) + worst-case refresh/search/rate/extra-action round trips. */
        private const val YTM_LIKE_WAKE_LOCK_MS = 60_000L

        fun dispatchExternalMediaEvent(context: Context, event: String) {
            val serviceIntent = Intent(context, MediaButtonForegroundService::class.java).apply {
                action = ACTION_EXTERNAL_MEDIA_EVENT
                putExtra(AppConstants.EXTRA_EVENT, event)
            }
            start(context, serviceIntent)
        }

        /**
         * Starts this service, surviving a refusal instead of crashing.
         *
         * The system can refuse a foreground-service start for reasons the
         * caller cannot test for beforehand: Android 12+ blocks most starts
         * from the background, and Android 15+ blocks whole service types from
         * a BOOT_COMPLETED receiver. The refusal arrives as
         * `ForegroundServiceStartNotAllowedException`, thrown in *this*
         * process — from a broadcast receiver that is an uncaught crash at
         * boot, which is a worse outcome than a listener that did not start.
         *
         * Caught as [IllegalStateException], its supertype: the exception
         * class itself is API 31 and this app runs back to 24, so naming it
         * would put a class the runtime cannot resolve in a catch clause.
         *
         * @return true if the start was accepted.
         */
        fun start(context: Context, intent: Intent): Boolean = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            true
        } catch (e: IllegalStateException) {
            // No Flutter engine and no service instance to broadcast through
            // on the paths that refuse, so this one goes to logcat.
            Log.w(TAG, "Service start refused (${intent.action}): ${e.message}")
            false
        }
    }
}
