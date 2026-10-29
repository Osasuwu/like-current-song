package com.osasuwu.like_spotify

import android.content.SharedPreferences

/**
 * The per-artist like count a background Spotify like raises -- the one the
 * stats screen reads -- and the undo that lowers it back (#281). A like
 * raises it for every artist on the track, follow-artist on or off, and the
 * leg is handed to the undo only after the count went up, so a like that did
 * not raise it leaves the undo nothing to lower. Out of the worker so the
 * pairing is unit-tested; the worker supplies the journal.
 */
internal object ArtistLikeCounting {

    /** Raises [artistId]'s like count by one, then hands [journal] the leg that lowers it back. */
    fun count(prefs: SharedPreferences, artistId: String, journal: (UndoLeg) -> Unit) {
        LocalCounters.increment(prefs, LocalCounters.Kind.ARTIST, artistId)
        journal(UndoLeg.ArtistLikeCount(artistId))
    }

    /** Reverts one [UndoLeg.ArtistLikeCount]: lowers [artistId]'s like count by one, never below zero. */
    fun undo(prefs: SharedPreferences, artistId: String) {
        LocalCounters.decrement(prefs, LocalCounters.Kind.ARTIST, artistId)
    }
}
