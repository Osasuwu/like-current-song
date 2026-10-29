package com.osasuwu.like_spotify

/**
 * Reverts a journalled like (#267), leg by leg, against whatever [Ops] talks
 * to Spotify. Free of Android APIs so the rules below are unit-tested; the
 * worker supplies the HTTP calls.
 *
 * Legs are reverted newest first, the reverse of how the like performed them,
 * and every leg is attempted even after one fails: a half-reverted like is
 * closer to the user's intent than a like left whole because its first leg
 * hit an error. Each failure is named so the log and the error tone can say
 * which leg it was.
 */
internal object UndoRunner {

    /** The Spotify calls an undo needs. A call may throw; that counts as its leg failing. */
    interface Ops {
        /** Removes [trackUri] from the user's library. */
        fun unsave(trackUri: String): ApiResult

        /** How many copies of [trackId] the playlist [playlistId] holds now. */
        fun countInPlaylist(playlistId: String, trackId: String): Int

        /** Removes every copy of [trackUri] from [playlistId] -- the only removal Spotify offers by URI. */
        fun removeAll(playlistId: String, trackUri: String): ApiResult

        /** Appends one copy of [trackUri] to [playlistId]. */
        fun add(playlistId: String, trackUri: String): ApiResult

        /** Drops [trackId] from the tracks this app remembers promoting into best (#273). */
        fun forgetPromoted(trackId: String)

        /** Drops [trackId] from this device's distinct tracks of [artistId] (#273). */
        fun forgetArtistTrack(artistId: String, trackId: String)

        /**
         * Clears the (user, [artistId], [trackId]) row from the counter sheet
         * [sheet]'s artist tab (#273); returns why it could not, or null.
         */
        fun clearArtistTrackRow(sheet: LikeCounter.Target, artistId: String, trackId: String): String?

        /** Unfollows [artistId] on Spotify. */
        fun unfollow(artistId: String): ApiResult

        /** Drops [artistId] from the artists this app remembers auto-following (#273). */
        fun forgetFollowed(artistId: String)

        /** Sets the cooldown's last-liked stamp of [trackId] back to [previous], or clears it when null. */
        fun restoreLikedAt(trackId: String, previous: Long?)

        /** Lowers [trackId]'s count on the Google Sheet [target] by one, never below 0 (#272). */
        fun decrementSheetCount(target: LikeCounter.Target, trackId: String): LikeCounter.CountOutcome

        /** Lowers [trackId]'s count on this device's fallback counter by one, never below 0 (#272). */
        fun decrementLocalCount(trackId: String)
    }

    /** The leg named [leg] could not be reverted, because of [reason]. */
    data class Failure(val leg: String, val reason: String)

    data class Result(val failures: List<Failure>) {
        val succeeded: Boolean get() = failures.isEmpty()
    }

    fun run(entry: UndoJournal.Entry, ops: Ops): Result {
        val trackId = entry.trackId
        val trackUri = entry.trackUri ?: trackId?.let { SpotifyLibraryEndpoints.trackUri(it) }
        val failures = mutableListOf<Failure>()
        for (leg in entry.legs.asReversed()) {
            val name = legName(leg)
            if (trackId == null || trackUri == null) {
                failures += Failure(name, "no track recorded")
                continue
            }
            val reason = try {
                revert(leg, trackId, trackUri, ops)
            } catch (t: Exception) {
                "${t.javaClass.simpleName}: ${t.message ?: "no message"}"
            }
            if (reason != null) failures += Failure(name, reason)
        }
        return Result(failures)
    }

    /** The name the log and a [Failure] give [leg]. */
    fun legName(leg: UndoLeg): String = when (leg) {
        is UndoLeg.NativeSave -> "native save"
        is UndoLeg.LikePlaylistAdd -> "like playlist"
        is UndoLeg.ArchiveRemove -> "archive playlist"
        is UndoLeg.BestPromote -> "best playlist"
        is UndoLeg.ArtistTrack -> "artist tally"
        is UndoLeg.ArtistTrackRow -> "artist tally sheet row"
        is UndoLeg.ArtistFollow -> "artist follow"
        is UndoLeg.CooldownStamp -> "cooldown stamp"
        is UndoLeg.TrackCount -> if (leg.sheet != null) "track counter (sheet)" else "track counter (this device)"
    }

    /** Reverts one leg; returns why it failed, or null. */
    private fun revert(leg: UndoLeg, trackId: String, trackUri: String, ops: Ops): String? = when (leg) {
        // Saved before the press: the like changed nothing in the library,
        // and unsaving would take away a save the user made themselves.
        is UndoLeg.NativeSave -> if (leg.alreadySaved) null else reason(ops.unsave(trackUri))

        // The like appended one copy. Spotify can only remove a track by URI,
        // which takes every copy, so remove them all and put back the ones
        // that were there before the press.
        is UndoLeg.LikePlaylistAdd -> {
            val copies = ops.countInPlaylist(leg.playlistId, trackId)
            if (copies == 0) {
                null
            } else {
                reason(ops.removeAll(leg.playlistId, trackUri))
                    ?: addCopies(ops, leg.playlistId, trackUri, copies - 1)
            }
        }

        is UndoLeg.ArchiveRemove -> addCopies(ops, leg.playlistId, trackUri, leg.copies)

        // The promotion appended one copy, exactly as the like playlist's add
        // did, so it comes out the same way. The promoted mark goes only once
        // the copy is out: a failed removal leaves a track that is still in
        // best still marked as promoted.
        is UndoLeg.BestPromote ->
            revert(UndoLeg.LikePlaylistAdd(leg.playlistId), trackId, trackUri, ops)
                ?: run { ops.forgetPromoted(trackId); null }

        // On the phone only; a throw is its one way to fail.
        is UndoLeg.ArtistTrack -> {
            ops.forgetArtistTrack(leg.artistId, trackId)
            null
        }

        is UndoLeg.ArtistTrackRow -> ops.clearArtistTrackRow(leg.sheet, leg.artistId, trackId)

        // Followed before the press: the like followed no one, and the undo
        // must not take away a follow the user made themselves. The followed
        // mark goes only once the unfollow went through, as best's does.
        is UndoLeg.ArtistFollow -> if (leg.alreadyFollowed) {
            null
        } else {
            reason(ops.unfollow(leg.artistId)) ?: run { ops.forgetFollowed(leg.artistId); null }
        }

        // On the phone only; a throw is its one way to fail.
        is UndoLeg.CooldownStamp -> {
            ops.restoreLikedAt(trackId, leg.previous)
            null
        }

        // Lowers the counter the like raised and only that one: a Sheet that
        // cannot be reached now fails this leg rather than lowering this
        // device's count, which the like never touched.
        is UndoLeg.TrackCount -> {
            val sheet = leg.sheet
            if (sheet == null) {
                ops.decrementLocalCount(trackId)
                null
            } else {
                val outcome = ops.decrementSheetCount(sheet, trackId)
                outcome.failure?.let { reason -> outcome.httpCode?.let { "$reason (HTTP $it)" } ?: reason }
            }
        }
    }

    private fun addCopies(ops: Ops, playlistId: String, trackUri: String, copies: Int): String? {
        repeat(copies) { reason(ops.add(playlistId, trackUri))?.let { return it } }
        return null
    }

    private fun reason(result: ApiResult): String? =
        if (result.success) null else "HTTP ${result.statusCode}" + (result.errorBody?.let { ": $it" } ?: "")
}
