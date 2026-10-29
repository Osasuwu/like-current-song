package com.osasuwu.like_spotify

import android.content.SharedPreferences

/**
 * Where a trigger's like goes (#268). It runs natively whether or not the app
 * is open: delegating to Dart while Flutter was attached left those likes out
 * of the undo journal, so a repeat could not undo them. The app shows the
 * result through the log events and the undo-window event instead.
 *
 * Only the Spotify job journals what it does, so only its likes can be undone
 * by repeating the trigger (#267); YouTube Music is #274.
 */
object TriggerLike {

    /**
     * Likes on [provider]: Spotify gets a journal entry opened at [now] and
     * hands its id to [likeOnSpotify] (the worker); YouTube Music goes to
     * [likeOnYouTubeMusic].
     */
    fun run(
        prefs: SharedPreferences,
        provider: MusicProvider,
        now: Long,
        afterUndo: Boolean,
        likeOnSpotify: (pressId: String, afterUndo: Boolean) -> Unit,
        likeOnYouTubeMusic: () -> Unit,
    ) {
        when (provider) {
            MusicProvider.SPOTIFY -> likeOnSpotify(UndoJournal.beginLike(prefs, now), afterUndo)
            MusicProvider.YTMUSIC -> likeOnYouTubeMusic()
        }
    }
}
