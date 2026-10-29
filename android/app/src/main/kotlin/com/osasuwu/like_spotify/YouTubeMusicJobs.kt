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
 *
 * The queue lives in memory only. If the process dies mid-like, the journal
 * entry stays LIKING and goes stale after the undo window, so the next press
 * likes again; but a repeat already queued as an undo is dropped, with no
 * tone and no log line.
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
        YouTubeMusicLikeSequence.run(object : YouTubeMusicLikeSequence.Steps<YouTubeMusicLiker.Outcome> {
            override fun like() = liker.like()

            override fun tone(liked: YouTubeMusicLiker.Outcome) = FeedbackPlayer.play(app, liked.positive)

            override fun openWindow(beforeUndoLine: () -> Unit) =
                liker.closePress(System.currentTimeMillis(), report(app, beforeUndoLine))

            override fun undoAccepted() = liker.undoAccepted()

            override fun count(liked: YouTubeMusicLiker.Outcome) = liker.count(liked)

            override fun extras(outcome: YouTubeMusicLiker.Outcome) = liker.extraActions(outcome)

            override fun logLike(outcome: YouTubeMusicLiker.Outcome) = this@YouTubeMusicJobs.logLike(app, outcome)

            override fun failed(error: Exception) {
                FeedbackPlayer.play(app, false)
                log(app, "YouTube Music like failed: ${error.message}", "like_track", "failure")
            }
        })
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
