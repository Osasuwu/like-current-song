package com.osasuwu.like_spotify

/**
 * How far a background like had got when something threw.
 *
 * [SpotifyLikeWorker] catches everything the job can throw in one place, so
 * that the user gets a log line and a failure tone instead of silence. But one
 * catch meant one label: every throw was filed as `like_track`, so a refresh
 * Google rejected, a playlist that could not be read and a tone generator that
 * blew up *after* the song was already liked all read the same on the Logs
 * screen (#191). The worker carries the stage it is in; the catch reads it.
 *
 * Pure on purpose: a [androidx.work.Worker] needs Android to run and the unit
 * tests here have none, so the part worth testing — which label, which words —
 * lives out here where plain JUnit can reach it.
 */
enum class LikeJobStage(
    /** What the Logs screen files a failure here under. */
    val actionType: String,
    /** Names the step: "Like failed while <step>". */
    val step: String,
    /** Whether the song is already liked by the time this stage runs. */
    val likeAlreadyDone: Boolean = false,
) {
    /** Reading the config and the stored tokens; nothing has gone out yet. */
    STARTING("like_job", "starting the like"),

    /** Exchanging a Spotify refresh token that is about to expire. */
    REFRESHING_TOKEN("spotify_token_refresh", "refreshing the Spotify token"),

    /** Asking Spotify what is playing right now. */
    READING_TRACK("current_track", "reading the current track"),

    /** Sending the like itself, on whichever legs the destination asks for. */
    LIKING("like_track", "liking the track"),

    /** The feedback tone and the cooldown stamp, the like already through. */
    RECORDING_LIKE("like_job", "recording the like", likeAlreadyDone = true),

    /** The rules that run after the like: archive, best, artists, counting. */
    EXTRA_ACTIONS("like_rules", "running the extra actions", likeAlreadyDone = true),
    ;

    /**
     * The Logs line for [t] thrown in this stage.
     *
     * A stage past the like says so rather than claiming the like failed: a
     * user whose song *is* liked should not be told it is not.
     */
    fun failureLine(t: Throwable): String {
        val detail = "${t.javaClass.simpleName}: ${t.message ?: "no message"}"
        return if (likeAlreadyDone) {
            "The track was liked, but $step failed: $detail"
        } else {
            "Like failed while $step: $detail"
        }
    }
}
