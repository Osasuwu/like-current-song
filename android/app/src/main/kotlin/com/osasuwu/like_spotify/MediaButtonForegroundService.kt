package com.osasuwu.like_spotify

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.media.AudioManager
import android.media.AudioPlaybackConfiguration
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.localbroadcastmanager.content.LocalBroadcastManager

class MediaButtonForegroundService : Service() {
    private lateinit var detector: MediaEventPatternDetector
    private var stoppedByUser = false

    /**
     * Refuses a match another app's audio caused (#248). Fed by
     * [playbackCallback]; both it and [onMediaEvent] run on the main thread.
     */
    private val veto = ExternalPlaybackVeto()

    /** API 26+ only; null below, where the veto has no history and passes. */
    private var playbackCallback: Any? = null

    /**
     * Keeps the notification's words true while the service runs: notification
     * access can be granted or revoked at any moment, and the text depends on
     * it. Sent by [PlaybackNotificationListenerService] when it connects or
     * disconnects, and by [MainActivity] whenever it re-reads the grant.
     */
    private val listenerStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            // Journal first, so the re-post cannot carry an Undo whose window passed.
            syncUndoAction()
            refreshNotification()
        }
    }

    /**
     * The like the notification offers Undo for (#269), null when it offers
     * none. Mirrors [UndoJournal.openWindow]; [syncUndoAction] keeps it there.
     */
    private var shownUndo: String? = null

    /**
     * Set first thing in [onDestroy]. A journal write queued just before it
     * still reaches [journalListener] afterwards; this keeps that late call
     * from re-posting a notification no service backs, or re-arming the timer.
     */
    private var destroyed = false

    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * The triple-tap mode's media-key listener (#158), for this start. It
     * registers only while the mode is on and the grant is there.
     */
    private var tripleTap: TripleTapListener? = null

    /** The mode was switched, or the screen re-read its status: re-sync. */
    private val tripleTapReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            syncTripleTap()
        }
    }

    /** Takes the action down once the window it was offered in has passed. */
    private val undoWindowCheck = Runnable { syncUndoAction() }

    /**
     * [undoWindowCheck] runs on uptime, which stops while the device sleeps,
     * and a like usually fires with the screen off. So the action is checked
     * again whenever the screen comes back, before the user can see a stale
     * one: [UndoJournal.openWindow] reads the wall clock.
     */
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            syncUndoAction()
        }
    }

    /**
     * Sees every journal write in this process — a like finishing in the
     * worker, an undo started by the gesture, by this notification, or by any
     * other surface — so the action appears and goes away with the window
     * whoever moved it. Held in a field: [SharedPreferences] keeps its
     * listeners weakly. Called on the main thread.
     */
    private val journalListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == AppConstants.KEY_UNDO_JOURNAL) syncUndoAction()
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        LocalBroadcastManager.getInstance(this).registerReceiver(
            listenerStateReceiver,
            IntentFilter(AppConstants.ACTION_LISTENER_STATE_CHANGED)
        )

        detector = MediaEventPatternDetector(
            windowMsProvider = { prefs().getLong(AppConstants.KEY_WINDOW_MS, 1000L) },
            debounceMsProvider = { prefs().getLong(AppConstants.KEY_DEBOUNCE_MS, 650L) },
            patternProvider = { loadPattern() }
        )
        watchActivePlayers()

        // This service owns no MediaSession, on purpose (#300). The headset
        // press reaches us through PlaybackNotificationListenerService, as the
        // player's state change. A session of our own never received a press
        // in normal use, but it was not harmless: Android gives the media
        // button to the most recently *started* playback whose owner has a
        // session, and the feedback tone (FeedbackPlayer) is such a playback.
        // So for ~450 ms after every like, undo or error tone our empty session
        // held the button, swallowed any press that landed in that window, and
        // the Bluetooth stack re-addressed the headset to it (state=null) and
        // back. With no session at all Android skips this UID and the button
        // stays with the player, tone or no tone. NoOwnMediaSessionTest keeps
        // it that way.

        startForeground(AppConstants.NOTIFICATION_ID, buildNotification(active = true))
        sendServiceState(true)
        prefs().registerOnSharedPreferenceChangeListener(journalListener)
        registerScreenReceiver()
        // A like may have finished while the service was down.
        syncUndoAction()
        if (!PlaybackNotificationListenerService.isEnabled(this)) {
            // Say it once, so the Logs screen is not silent about the reason
            // nothing ever happens.
            log(
                "Notification access is off — the trigger cannot see pause/play",
                actionType = "notification_listener",
                result = "failure",
            )
        }
        tripleTap = TripleTapListener(
            this,
            mainHandler,
            onPress = ::onTripleTap,
            log = { message, result -> log(message, actionType = "triple_tap", result = result) },
        )
        LocalBroadcastManager.getInstance(this).registerReceiver(
            tripleTapReceiver,
            IntentFilter(AppConstants.ACTION_TRIPLE_TAP_CHANGED)
        )
        syncTripleTap()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> stopSelfSafely()
            ACTION_UNDO -> onUndoTapped(intent.getStringExtra(EXTRA_PRESS_ID))
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
        destroyed = true
        mainHandler.removeCallbacks(undoWindowCheck)
        prefs().unregisterOnSharedPreferenceChangeListener(journalListener)
        runCatching { unregisterReceiver(screenReceiver) }
        runCatching {
            LocalBroadcastManager.getInstance(this).unregisterReceiver(listenerStateReceiver)
        }
        runCatching {
            LocalBroadcastManager.getInstance(this).unregisterReceiver(tripleTapReceiver)
        }
        // Frees the media keys; an app kill frees them too (the system watches the binder).
        tripleTap?.close()
        tripleTap = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            (playbackCallback as? AudioManager.AudioPlaybackCallback)?.let { callback ->
                runCatching {
                    getSystemService(AudioManager::class.java)?.unregisterAudioPlaybackCallback(callback)
                }
            }
        }
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
        val now = System.currentTimeMillis()
        if (detector.onEvent(event, now)) {
            log("Trigger matched: ${loadPattern().joinToString(" -> ")}")
            val started = veto.startedPlayers(now)
            if (started.isNotEmpty()) {
                // An unwanted like is worse than a missed one: when another
                // app's audio may have caused the pause, do nothing.
                log(
                    "Trigger vetoed: another app started playing around the pause " +
                        "(usage ${started.joinToString { it.usage.toString() }})",
                    actionType = "trigger_veto",
                )
                return
            }
            // Asked after the veto: a vetoed repeat neither likes nor undoes.
            handlePress(now)
        }
    }

    /**
     * A press the triple-tap listener kept (#158). Already answered, so the
     * player never saw it; from here it is the same press as a matched
     * pattern. The #248 veto does not apply: no pause, no other app's audio.
     */
    private fun onTripleTap() {
        if (destroyed) return
        log("Triple tap on the earbuds", actionType = "triple_tap")
        handlePress(System.currentTimeMillis())
    }

    /** Re-reads the mode and lets the listener register or let go. */
    private fun syncTripleTap() {
        if (destroyed) return
        tripleTap?.sync(prefs().getBoolean(AppConstants.KEY_TRIPLE_TAP_ENABLED, false))
    }

    /**
     * One press of the trigger, whatever produced it: a like, or the undo of
     * the last one when it repeats inside [UndoJournal.WINDOW_MS].
     */
    private fun handlePress(now: Long) {
        val press = UndoJournal.onPress(prefs(), now)
        when (press) {
            is UndoJournal.Press.Undo -> {
                log("Trigger repeated within ${UndoJournal.WINDOW_MS / 1000} s of a like: undoing it", actionType = "undo")
                undo(press.pressId)
            }
            UndoJournal.Press.QueueUndo ->
                log("Trigger repeated while the like is still running: it undoes itself when done", actionType = "undo")
            UndoJournal.Press.Ignore ->
                log("Trigger repeated again: the undo is already under way", actionType = "undo")
            is UndoJournal.Press.Like -> like(press.afterUndo)
        }
    }

    /**
     * The notification's Undo (#269). Starts the same undo a repeat of the
     * trigger would — same worker job, same tone, same end state — and only
     * for the like the action was offered for, only inside its window.
     */
    private fun onUndoTapped(pressId: String?) {
        val tap = UndoActionSync.tap(
            prefs(),
            pressId,
            System.currentTimeMillis(),
            startUndo = ::undo,
            // A visible button that did nothing must not be silent.
            tooLate = { FeedbackPlayer.play(this, FeedbackKind.ERROR) },
        )
        when (tap) {
            UndoActionSync.Tap.UNDO ->
                log("Undo tapped in the notification: undoing the last like", actionType = "undo")
            UndoActionSync.Tap.ALREADY_UNDOING ->
                log("Undo tapped while the undo is already under way", actionType = "undo")
            UndoActionSync.Tap.TOO_LATE ->
                log("Undo tapped, but that like can no longer be undone: nothing undone", actionType = "undo")
        }
        // Stale or not, the action must not stay up.
        syncUndoAction()
    }

    /**
     * Brings the notification's Undo action in line with the journal: shown
     * while [UndoJournal.openWindow] has a like, gone the moment it has none.
     * [UndoActionSync.next] decides; this applies it. Stopping removed the
     * notification and destruction leaves no service behind it, so a late
     * journal write then posts and re-arms nothing.
     */
    private fun syncUndoAction() {
        mainHandler.removeCallbacks(undoWindowCheck)
        val halted = destroyed || stoppedByUser
        val now = System.currentTimeMillis()
        val window = if (halted) null else UndoJournal.openWindow(prefs(), now)
        val plan = UndoActionSync.next(window, shownUndo, now, halted)
        shownUndo = plan.offer
        if (plan.repost) refreshNotification()
        plan.recheckInMs?.let { mainHandler.postDelayed(undoWindowCheck, it) }
    }

    private fun registerScreenReceiver() {
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        // System broadcasts still reach a not-exported receiver.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(screenReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(screenReceiver, filter)
        }
    }

    /**
     * A trigger's like, natively whether or not the app is open; [TriggerLike]
     * decides where it goes (#268): Spotify via WorkManager, YouTube Music
     * in-process.
     *
     * The service is resolved here rather than in Dart because the trigger
     * always likes on this path, app open or not. [MusicProvider.resolve] is
     * the same rule Dart runs.
     */
    private fun like(afterUndo: Boolean) {
        val routing = MusicProvider.resolve(this)
        if (routing.automatic) {
            log(routing.logLine(), actionType = "music_routing")
        }
        TriggerLike.run(
            prefs(),
            routing.provider,
            System.currentTimeMillis(),
            afterUndo,
            likeOnSpotify = { pressId, after ->
                log("Liking on Spotify through WorkManager")
                SpotifyLikeWorker.enqueue(this, routing.provider, pressId, after)
            },
            likeOnYouTubeMusic = { pressId -> YouTubeMusicJobs.like(this, pressId) },
        )
    }

    /** Undoes the like [pressId] on the service that made it (#274). */
    private fun undo(pressId: String) = TriggerLike.undo(
        prefs(),
        pressId,
        undoOnSpotify = { SpotifyLikeWorker.enqueueUndo(this, it) },
        undoOnYouTubeMusic = { YouTubeMusicJobs.undo(this, it) },
    )

    /**
     * Feeds [veto] the active-player list: seeded now, then on every change.
     * No permission is needed — an ordinary app gets anonymised copies, which
     * still keep each player's identity and usage.
     */
    private fun watchActivePlayers() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val audioManager = getSystemService(AudioManager::class.java) ?: return
        fun record(configs: List<AudioPlaybackConfiguration>) {
            veto.onPlayersChanged(
                System.currentTimeMillis(),
                configs.map { ExternalPlaybackVeto.ActivePlayer(it, it.audioAttributes.usage) },
            )
        }
        runCatching {
            record(audioManager.activePlaybackConfigurations)
            val callback = object : AudioManager.AudioPlaybackCallback() {
                override fun onPlaybackConfigChanged(configs: MutableList<AudioPlaybackConfiguration>) {
                    record(configs)
                }
            }
            audioManager.registerAudioPlaybackCallback(callback, Handler(Looper.getMainLooper()))
            playbackCallback = callback
        }.onFailure {
            log("Cannot watch other apps' playback; the veto is off: ${it.message}", actionType = "trigger_veto")
        }
    }

    private fun normalizeExternalEvent(event: String?): String? {
        return when (event) {
            "play" -> "play"
            "pause" -> "pause"
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
        BackgroundLog.emit(this, message, actionType, result)
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

        val listenerEnabled = PlaybackNotificationListenerService.isEnabled(this)
        val text = ServiceNotificationText.body(listenerEnabled)

        val builder = NotificationCompat.Builder(this, AppConstants.NOTIFICATION_CHANNEL_ID)
            .setContentTitle(ServiceNotificationText.title(active, listenerEnabled))
            .setContentText(text)
            // The "off" text is longer than one collapsed line, and the one
            // person who needs to read it is the one it is addressed to.
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setSmallIcon(R.drawable.ic_stat_like)
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(openPendingIntent)

        val undoId = shownUndo
        for (action in ServiceNotificationText.actions(listenerEnabled, undoOpen = undoId != null)) {
            when (action) {
                NotificationAction.STOP -> builder.addAction(0, "Stop", stopPendingIntent)
                NotificationAction.GRANT_ACCESS -> grantAccessPendingIntent()?.let {
                    builder.addAction(0, ServiceNotificationText.GRANT_ACTION_LABEL, it)
                }
                NotificationAction.UNDO -> builder.addAction(
                    0,
                    ServiceNotificationText.UNDO_ACTION_LABEL,
                    undoPendingIntent(undoId!!),
                )
            }
        }

        return builder.build()
    }

    /**
     * Undoes the like [pressId]. Every Undo shares this one PendingIntent
     * identity, and [PendingIntent.FLAG_UPDATE_CURRENT] rewrites its extra on
     * each post, so the id is always the latest one offered. What keeps a
     * stale tap from undoing anything is [UndoJournal.requestUndo]: the latest
     * like, still finished, still inside its window.
     */
    private fun undoPendingIntent(pressId: String): PendingIntent {
        val undoIntent = Intent(this, MediaButtonForegroundService::class.java).apply {
            action = ACTION_UNDO
            putExtra(EXTRA_PRESS_ID, pressId)
        }
        return PendingIntent.getService(
            this,
            UNDO_REQUEST_CODE,
            undoIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }

    /** Opens the system's notification-access list, where the grant lives. */
    private fun grantAccessPendingIntent(): PendingIntent? {
        val settingsIntent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (settingsIntent.resolveActivity(packageManager) == null) {
            return null
        }
        return runCatching {
            PendingIntent.getActivity(
                this,
                GRANT_ACCESS_REQUEST_CODE,
                settingsIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
        }.getOrNull()
    }

    /**
     * Re-posts the notification so its text matches the grant as it is *now*.
     * Called whenever the listener connects or disconnects, and whenever the
     * app re-reads the grant — the state can change while the service runs, and
     * a notification written once at startup would keep lying afterwards.
     */
    private fun refreshNotification() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        runCatching {
            manager.notify(AppConstants.NOTIFICATION_ID, buildNotification(active = true))
        }
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
     * this brings it back.
     *
     * **This is not [start]**, and deliberately so. [start] is an in-process
     * start, where a refusal lands in this app's process; here the start is
     * performed by `system_server` on our behalf, when the alarm fires, and a
     * refusal never leaves `system_server`:
     *
     * - `AlarmManagerService` delivers the alarm by sending the [PendingIntent],
     *   which runs `PendingIntentRecord.sendInner` — `PendingIntentRecord` is an
     *   `IIntentSender.Stub` inside `system_server`, so `sendInner` always runs
     *   there regardless of who called `send`.
     * - For `INTENT_SENDER_FOREGROUND_SERVICE`, `sendInner` calls
     *   `ActivityManagerInternal.startServiceInPackage` — a `LocalServices`
     *   abstract class, "Only for use within the system server", so a plain
     *   in-process call with no binder hop — inside
     *   `catch (RuntimeException e) { Slog.w(TAG, "Unable to send startService
     *   intent", e); }`.
     * - `ForegroundServiceStartNotAllowedException` extends
     *   `ServiceStartNotAllowedException` extends `IllegalStateException`
     *   extends `RuntimeException`, so that catch swallows it and logs it there.
     *   The other denial shape, `ActiveServices.startServiceLocked` returning
     *   `ComponentName("?", msg)`, is discarded by `sendInner` outright — only
     *   `ContextImpl.startServiceCommon` turns that marker into an exception,
     *   and that code runs in the *app's* process, which this path never enters.
     *
     * So this app only ever learns the alarm-fired start was refused by not
     * being started: there is nothing here to catch, and routing this through
     * [start] would be impossible anyway — the start happens later, in another
     * process. The [runCatching] below guards `AlarmManager.set` itself, which
     * is a different failure (an exact-alarm or quota refusal at schedule time).
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
        private const val ACTION_UNDO = "ACTION_UNDO"
        private const val EXTRA_PRESS_ID = "press_id"
        private const val TAG = "LikeSpotifyService"
        private const val RESTART_REQUEST_CODE = 5
        private const val GRANT_ACCESS_REQUEST_CODE = 6
        private const val UNDO_REQUEST_CODE = 7
        private const val RESTART_DELAY_MS = 1000L

        /**
         * Tells a running service that notification access was granted or
         * revoked, so it can re-word its notification. A local broadcast on
         * purpose: it must not start the service, only reach one that is
         * already up.
         */
        fun notifyListenerStateChanged(context: Context) {
            LocalBroadcastManager.getInstance(context)
                .sendBroadcast(Intent(AppConstants.ACTION_LISTENER_STATE_CHANGED))
        }

        fun dispatchExternalMediaEvent(context: Context, event: String) {
            val serviceIntent = Intent(context, MediaButtonForegroundService::class.java).apply {
                action = ACTION_EXTERNAL_MEDIA_EVENT
                putExtra(AppConstants.EXTRA_EVENT, event)
            }
            start(context, serviceIntent)
        }

        /**
         * Starts this service **from this process, right now**, surviving a
         * refusal instead of crashing. Every direct
         * `startForegroundService`/`startService` call in this app goes
         * through here. The one start that does *not* is the alarm-fired
         * `PendingIntent` in [scheduleRestart], which `system_server` performs
         * on our behalf — see that method for why a refusal there cannot reach
         * us and so needs no catch.
         *
         * The system can refuse a foreground-service start for reasons the
         * caller cannot test for beforehand: Android 12+ blocks most starts
         * from the background, and Android 15+ blocks whole service types from
         * a BOOT_COMPLETED receiver. Because the start is in-process, the
         * refusal surfaces *here*: AMS answers the binder call with the
         * `ComponentName("?", msg)` marker and `ContextImpl.startServiceCommon`
         * — app-side code — turns it into
         * `ForegroundServiceStartNotAllowedException` and throws it on this
         * very stack. From a broadcast receiver that is an uncaught crash at
         * boot, which is a worse outcome than a listener that did not start.
         *
         * Caught as [IllegalStateException], its supertype: the exception
         * class itself is API 31 and this app runs back to 24, so naming it
         * would put a class the runtime cannot resolve in a catch clause.
         *
         * @return true if the start was accepted. A caller that persists "the
         *   listener is on" must gate that write on this, or the app ends up
         *   claiming to listen while nothing runs. [MainActivity] does exactly
         *   that. [BootCompletedReceiver] deliberately does not: the flag it
         *   would clear is the only record that the user ever asked for the
         *   listener, there is no UI at boot to tell them it was dropped, and
         *   leaving it set is what lets opening the app bring the listener
         *   back.
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
