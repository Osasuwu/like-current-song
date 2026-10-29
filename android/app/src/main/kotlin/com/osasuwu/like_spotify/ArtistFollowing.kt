package com.osasuwu.like_spotify

import android.content.SharedPreferences
import java.net.HttpURLConnection

/**
 * The follow-artist steps of a background Spotify like that leave something
 * for an undo to revert (#273), each paired with the leg it hands the undo
 * (#282): the track added to this device's tally of the artist, the row
 * appended to the shared sheet's tally, and the follow itself. Out of the
 * worker so each pairing is unit-tested; the worker supplies the journal and
 * the Spotify calls.
 */
internal object ArtistFollowing {

    /**
     * The distinct-track count the follow decision reads for [artistId], with
     * [trackId] recorded on this device's tally first: [shared]'s answer when
     * it gives one, else this device's. [journal] gets an [UndoLeg.ArtistTrack]
     * only when this call added the track to the local tally.
     */
    fun trackCount(
        prefs: SharedPreferences,
        artistId: String,
        trackId: String,
        journal: (UndoLeg) -> Unit,
        shared: () -> Int?,
    ): Int = LocalCounters.artistFollowCount(
        prefs,
        artistId,
        trackId,
        onAdded = { journal(UndoLeg.ArtistTrack(artistId)) },
        shared = shared,
    )

    /**
     * Records [trackId] on the shared sheet's tally of [artistId] at [target].
     * [journal] gets an [UndoLeg.ArtistTrackRow] only when this call appended
     * the row, so an undo clears a row this like wrote and no other.
     */
    fun sheetTrackCount(
        prefs: SharedPreferences,
        target: LikeCounter.Target,
        artistId: String,
        trackId: String,
        journal: (UndoLeg) -> Unit,
        connect: (String) -> HttpURLConnection = LikeCounter.NETWORK,
    ): LikeCounter.CountOutcome =
        LikeCounter.recordArtistTrack(prefs, target, artistId, trackId, connect) {
            journal(UndoLeg.ArtistTrackRow(artistId, target))
        }

    /**
     * Follows [artistId] through [follow] and answers its result. On success
     * the artist is remembered as auto-followed and [journal] gets an
     * [UndoLeg.ArtistFollow]; [wasFollowing] is what Spotify said before the
     * follow, and anything but a plain "no" counts as already followed, so an
     * undo never unfollows an artist the user followed themselves.
     */
    fun follow(
        prefs: SharedPreferences,
        artistId: String,
        wasFollowing: Boolean?,
        journal: (UndoLeg) -> Unit,
        follow: () -> ApiResult,
    ): ApiResult {
        val result = follow()
        if (result.success) {
            LocalCounters.markArtistFollowed(prefs, artistId)
            journal(UndoLeg.ArtistFollow(artistId, alreadyFollowed = wasFollowing != false))
        }
        return result
    }
}
