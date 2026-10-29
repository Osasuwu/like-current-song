package com.osasuwu.like_spotify

import android.content.SharedPreferences

/**
 * Where a trigger's like goes (#268), and where its undo goes. It runs
 * natively whether or not the app is open: delegating to Dart while Flutter
 * was attached left those likes out of the undo journal, so a repeat could not
 * undo them. The app shows the result through the log events and the
 * undo-window event instead.
 *
 * Both services journal what they do, so a repeat undoes a like on either
 * (#267 Spotify, #274 YouTube Music).
 */
object TriggerLike {

    /**
     * Likes on [provider]: a journal entry opened at [now] for that service
     * hands its id to [likeOnSpotify] (the worker) or [likeOnYouTubeMusic].
     */
    fun run(
        prefs: SharedPreferences,
        provider: MusicProvider,
        now: Long,
        afterUndo: Boolean,
        likeOnSpotify: (pressId: String, afterUndo: Boolean) -> Unit,
        likeOnYouTubeMusic: (pressId: String) -> Unit,
    ) {
        when (provider) {
            MusicProvider.SPOTIFY -> likeOnSpotify(UndoJournal.beginLike(prefs, now), afterUndo)
            // No afterUndo: the trigger's YouTube Music likes and undos share
            // one queue, so a like after an undo already runs after it. (The
            // app's "Like current track now" button runs elsewhere, but it
            // journals nothing, so it has nothing to undo.)
            MusicProvider.YTMUSIC -> likeOnYouTubeMusic(UndoJournal.beginLike(prefs, now, MusicProvider.YTMUSIC))
        }
    }

    /**
     * Undoes the like journalled under [pressId] on the service that made it.
     * An entry no longer in the journal goes to Spotify, whose undo logs it
     * and plays the error tone.
     */
    fun undo(
        prefs: SharedPreferences,
        pressId: String,
        undoOnSpotify: (pressId: String) -> Unit,
        undoOnYouTubeMusic: (pressId: String) -> Unit,
    ) {
        when (UndoJournal.entry(prefs, pressId)?.provider) {
            MusicProvider.YTMUSIC -> undoOnYouTubeMusic(pressId)
            else -> undoOnSpotify(pressId)
        }
    }
}
