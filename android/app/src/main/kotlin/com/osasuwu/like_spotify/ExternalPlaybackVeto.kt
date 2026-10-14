package com.osasuwu.like_spotify

import android.media.AudioAttributes

/**
 * Tells a matched `pause, play` the user made from one another app caused
 * (#248).
 *
 * An app taking audio focus pauses the music, and when it lets go the music
 * resumes: to the trigger that is the user's gesture. What gives it away is a
 * player that was not active a moment ago becoming active around the pause.
 * The music app's own resume is not that — its player leaves the active list
 * at the pause and rejoins it under the same identity.
 *
 * Fed the active-player snapshots `AudioManager.AudioPlaybackCallback`
 * delivers, timestamped on the detector's clock. Pure on purpose, so the rule
 * is tested without an AudioManager. With no snapshots at all (API 24–25 have
 * no callback) it vetoes nothing.
 *
 * When in doubt it vetoes: an unwanted like is worse than a missed one.
 */
class ExternalPlaybackVeto(
    private val lookbackMs: Long = MediaEventPatternDetector.MAX_WINDOW_MS + LEAD_MS,
    private val retainMs: Long = RETAIN_MS,
) {
    /**
     * One active player. [id] is the platform's own configuration object,
     * compared by `equals`: the copies an ordinary app receives are anonymised
     * but keep the player's identity.
     */
    data class ActivePlayer(val id: Any, val usage: Int)

    private val history = ArrayDeque<Pair<Long, List<ActivePlayer>>>()

    fun onPlayersChanged(atMs: Long, players: List<ActivePlayer>) {
        history.addLast(atMs to players)
        // The newest snapshot older than the retention stays: it is the
        // baseline a later lookback compares against.
        val cutoff = atMs - retainMs
        while (history.size > 1 && history[1].first <= cutoff) {
            history.removeFirst()
        }
    }

    /**
     * The players that became active in the [lookbackMs] before [nowMs] and
     * were not active when it began, less the sounds a user's own gesture
     * makes. Non-empty means veto.
     */
    fun startedPlayers(nowMs: Long): List<ActivePlayer> {
        val from = nowMs - lookbackMs
        val baseline = history.lastOrNull { it.first <= from }?.second.orEmpty()
        return history
            .filter { it.first > from }
            .flatMap { it.second }
            .filter { it !in baseline && it.usage !in GESTURE_USAGES }
            .distinct()
    }

    private companion object {
        /** A player that starts this long before the pause still counts. */
        const val LEAD_MS = 500L
        const val RETAIN_MS = 10_000L

        /**
         * A tap on the notification shade clicks, and TalkBack speaks it:
         * both accompany the user's own gesture.
         */
        val GESTURE_USAGES = setOf(
            AudioAttributes.USAGE_ASSISTANCE_SONIFICATION,
            AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY,
        )
    }
}
