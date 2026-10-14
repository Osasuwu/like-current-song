package com.osasuwu.like_spotify

import android.media.session.PlaybackState

/**
 * Turns a media session's raw playback states into the `play` / `pause`
 * events the trigger matches on.
 *
 * Only STATE_PAUSED is a pause (#248). STOPPED and NONE are what a session
 * passes through when it is torn down, restarted or handed over, not what a
 * pause press produces; counted as pauses, an automatic resume read as the
 * `pause, play` gesture. They are dropped without touching the dedupe memory,
 * so a stop between two PLAYING states does not make the second one new.
 *
 * Pure on purpose — it holds only the dedupe memory, so the rules can be
 * tested without a live [android.media.session.MediaController].
 */
class PlaybackStateFilter {
    private val lastStateBySession = mutableMapOf<String, Int>()

    /**
     * The event [rawState] stands for, or null when it is none or repeats
     * what this session last reported.
     *
     * The memory is per session, not per app: one app can hold several
     * sessions, and a shared per-app entry let one session's pause make the
     * other's repeated PLAYING look like a fresh play.
     */
    fun onState(sessionKey: String, rawState: Int): String? {
        val mapped = when (rawState) {
            PlaybackState.STATE_PLAYING -> "play"
            PlaybackState.STATE_PAUSED -> "pause"
            else -> null
        } ?: return null

        if (lastStateBySession[sessionKey] == rawState) {
            return null
        }
        lastStateBySession[sessionKey] = rawState
        return mapped
    }

    /** Drops the memory of a session that has gone away. */
    fun forget(sessionKey: String) {
        lastStateBySession.remove(sessionKey)
    }
}
