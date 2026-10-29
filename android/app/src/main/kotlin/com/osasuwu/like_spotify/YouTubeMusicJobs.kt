package com.osasuwu.like_spotify

import android.content.Context
import android.content.Intent
import android.os.PowerManager
import androidx.localbroadcastmanager.content.LocalBroadcastManager
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Runs a YouTube Music like from the trigger, and its undo, off the main
 * thread. The session like needs a live MediaController, which a WorkManager
 * job can't carry, so both run on one process-wide thread under a partial
 * wake lock (the screen is usually off when the trigger fires). One thread
 * means an undo always runs after the like it reverts, the way Spotify's undo
 * job is chained after its like job (#274).
 */
internal object YouTubeMusicJobs {

    /** Session confirm (~2 s) + worst-case refresh/search/rate/extra-action round trips. */
    private const val WAKE_LOCK_MS = 60_000L

    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    /** Likes the playing song for the press [pressId], then counts it and runs the extras. */
    fun like(context: Context, pressId: String) =
        submit(context, "LikeSpotify:ytmusic-like") { app -> runLike(app, pressId) }

    /** Undoes the like journalled under [pressId]. */
    fun undo(context: Context, pressId: String) =
        submit(context, "LikeSpotify:ytmusic-undo") { app ->
            YouTubeMusicLiker(app, pressId).undo(report(app) {})
        }

    private fun runLike(app: Context, pressId: String) {
        val liker = YouTubeMusicLiker(app, pressId)
        // The like's own line is written before any undo line about it, even
        // when a repeat during the like undoes it before it is counted.
        var pendingLikeLine: (() -> Unit)? = null
        val report = report(app) {
            pendingLikeLine?.invoke()
            pendingLikeLine = null
        }
        try {
            val liked = liker.like()
            FeedbackPlayer.play(app, liked.positive)
            pendingLikeLine = { logLike(app, liked) }
            // The window opens at the tone. A repeat that came in during the
            // like is answered here, and an undone like earns no counters.
            if (liker.closePress(System.currentTimeMillis(), report)) {
                pendingLikeLine?.invoke()
                return
            }
            pendingLikeLine = null
            // After the tone: counting may take a search and an RPC, and it
            // never changes whether the like succeeded.
            val outcome = runCatching { liker.count(liked) }.getOrDefault(liked)
            logLike(app, outcome)
            // The opt-in extras come last: they cost API quota, they can be
            // slow, and they only ever log.
            runCatching { liker.extraActions(outcome) }
        } catch (e: Exception) {
            FeedbackPlayer.play(app, false)
            log(app, "YouTube Music like failed: ${e.message}", "like_track", "failure")
        } finally {
            // A like that threw still closes its entry: a repeat queued during
            // it is answered, and the next press likes again.
            runCatching { liker.closePress(System.currentTimeMillis(), report) }
        }
    }

    private fun logLike(app: Context, outcome: YouTubeMusicLiker.Outcome) =
        log(app, outcome.logLine(), "like_track", if (outcome.positive) "success" else "failure")

    private fun report(app: Context, beforeLine: () -> Unit) = object : UndoCompletion.Report {
        override fun log(message: String, result: String, targetId: String?) {
            beforeLine()
            log(app, message, "undo", result, targetId)
        }

        override fun tone(kind: FeedbackKind) = FeedbackPlayer.play(app, kind)
    }

    private fun submit(context: Context, tag: String, job: (Context) -> Unit) {
        val app = context.applicationContext
        val power = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        val wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, tag)
        wakeLock.setReferenceCounted(false)
        wakeLock.acquire(WAKE_LOCK_MS)
        val submitted = runCatching {
            executor.execute {
                try {
                    job(app)
                } finally {
                    if (wakeLock.isHeld) wakeLock.release()
                }
            }
        }
        if (submitted.isFailure && wakeLock.isHeld) wakeLock.release()
    }

    private fun log(app: Context, message: String, actionType: String, result: String, targetId: String? = null) {
        BackgroundLog.emit(app, message, actionType, result, targetId)
        val intent = Intent(AppConstants.ACTION_LOG_EVENT)
            .putExtra(AppConstants.EXTRA_LOG, message)
            .putExtra(AppConstants.EXTRA_LOG_ACTION_TYPE, actionType)
            .putExtra(AppConstants.EXTRA_LOG_RESULT, result)
        if (targetId != null) intent.putExtra(AppConstants.EXTRA_LOG_TARGET_ID, targetId)
        LocalBroadcastManager.getInstance(app).sendBroadcast(intent)
    }
}
