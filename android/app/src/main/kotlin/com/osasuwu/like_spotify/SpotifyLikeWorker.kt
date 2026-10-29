package com.osasuwu.like_spotify

import android.content.Context
import android.content.SharedPreferences
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URLEncoder
import java.net.URL

/**
 * Background worker for liking the current Spotify track when the Flutter engine
 * is not attached (background media-button trigger via WorkManager).
 *
 * Mirrors the canonical rule pipeline in the Dart layer
 * ([SpotifyMusicServiceRepository.likeTrack]): like -> remove from archive playlist
 * (non-blocking) -> increment track like count (counter sheet first, local fallback) ->
 * promote to best playlist at threshold -> increment the like count of every artist
 * on the track (local only) -> auto-follow each that has reached the threshold.
 *
 * Also runs the undo gesture (#267). A like job journals each Spotify write it
 * makes ([UndoJournal]); a repeat of the trigger within [UndoJournal.WINDOW_MS]
 * either queues an undo job ([MODE_UNDO]) or, when it lands while the like is
 * still running, is picked up by that job once the like and the archive removal
 * are done. Either way [UndoRunner] reverts the journaled legs.
 */
class SpotifyLikeWorker(
    appContext: Context,
    params: WorkerParameters
) : Worker(appContext, params) {

    /**
     * How far [runLike] had got. Read by the one catch in [doWork], which
     * otherwise has no way of telling a refused token from a playlist that
     * could not be read, and used to file both as a failed like (#191).
     */
    @Volatile
    private var stage = LikeJobStage.STARTING

    /**
     * The [UndoJournal] entry of the press this job runs for (#267); null for
     * a job queued before the journal existed, which then journals nothing.
     */
    private var pressId: String? = null

    /** Whether [closePress] has run; it runs once, at the archive leg or on the way out. */
    private var pressClosed = false

    /** When the like's tone played; the undo window runs from it. */
    private var likedAt: Long? = null

    /** The access token the like ended up with, for an undo that runs inline. */
    private var likeToken: String? = null

    /**
     * Every HTTP call below can throw -- a dropped connection, a truncated
     * body, a non-JSON error page. Unguarded, that killed the whole job: no
     * log line, no failure tone, nothing the user could tell apart from the
     * trigger never firing. A retry is not the answer either, because
     * [currentTrack] resolves at run time, so a job that runs minutes later
     * would like whatever is playing by then. So: report, buzz, give up.
     */
    override fun doWork(): Result {
        pressId = inputData.getString(KEY_PRESS_ID)
        if (inputData.getString(KEY_MODE) == MODE_UNDO) return runUndoJob()
        return try {
            runLike()
        } catch (t: Throwable) {
            // Guarded in turn: a tone generator that throws on some OEM would
            // otherwise put us right back where we started.
            val failed = stage
            runCatching {
                log(
                    failed.failureLine(t),
                    actionType = failed.actionType,
                    result = "failure"
                )
            }
            // A stage past the like has the song liked already, so the buzz
            // that says "that did not work" would be a lie.
            runCatching { playFeedbackTone(success = failed.likeAlreadyDone) }
            Result.success()
        } finally {
            // A like that ended early or threw still closes its entry, so a
            // repeat that queued an undo meanwhile gets its answer.
            runCatching { closePress(prefs()) }
        }
    }

    private fun prefs(): SharedPreferences =
        applicationContext.getSharedPreferences(AppConstants.PREFS, Context.MODE_PRIVATE)

    /**
     * The stored access token, refreshed first when it expires within five
     * minutes. Null when there is none.
     */
    private fun accessToken(prefs: SharedPreferences): String? {
        val accessToken = prefs.getString(AppConstants.KEY_SPOTIFY_ACCESS_TOKEN, null)
        if (accessToken.isNullOrBlank()) return null
        val refreshToken = prefs.getString(AppConstants.KEY_SPOTIFY_REFRESH_TOKEN, null)
        val clientId = prefs.getString(AppConstants.KEY_SPOTIFY_CLIENT_ID, null)
        val expiresAt = prefs.getLong(AppConstants.KEY_SPOTIFY_EXPIRES_AT, 0L)
        val nowSec = System.currentTimeMillis() / 1000L
        if (expiresAt <= 0 || (expiresAt - nowSec) >= 300 || refreshToken.isNullOrBlank() || clientId.isNullOrBlank()) {
            return accessToken
        }
        stage = LikeJobStage.REFRESHING_TOKEN
        log("Token expires in ${expiresAt - nowSec}s, refreshing...")
        val refreshed = refreshAccessToken(refreshToken, clientId)
        if (refreshed == null || refreshed.accessToken.isBlank()) return accessToken
        val editor = prefs.edit()
            .putString(AppConstants.KEY_SPOTIFY_ACCESS_TOKEN, refreshed.accessToken)
        if (!refreshed.refreshToken.isNullOrBlank()) {
            editor.putString(AppConstants.KEY_SPOTIFY_REFRESH_TOKEN, refreshed.refreshToken)
        }
        if (refreshed.expiresInSec != null && refreshed.expiresInSec > 0) {
            editor.putLong(AppConstants.KEY_SPOTIFY_EXPIRES_AT, (nowSec + refreshed.expiresInSec))
        }
        editor.apply()
        return refreshed.accessToken
    }

    private fun runLike(): Result {
        // The service the trigger resolved to, carried from enqueue time: the
        // job honours the decision that was made (and logged) rather than
        // resolving again against state that has since moved on. A job queued
        // before this input existed falls back to resolving now.
        val provider = inputData.getString(KEY_ROUTED_PROVIDER)
            ?.let { id -> MusicProvider.values().firstOrNull { it.id == id } }
            ?: MusicProvider.resolve(applicationContext).provider
        // Never send a Spotify request for another service's trigger.
        if (provider != MusicProvider.SPOTIFY) {
            log("Like skipped: music service is ${provider.displayName}, not Spotify", actionType = "like_track", result = "info")
            return Result.success()
        }

        val prefs = prefs()
        var accessToken = accessToken(prefs)
        if (accessToken.isNullOrBlank()) {
            log("Like skipped: Spotify access token missing", actionType = "like_track", result = "failure")
            playFeedbackTone(success = false)
            return Result.success()
        }
        val refreshToken = prefs.getString(AppConstants.KEY_SPOTIFY_REFRESH_TOKEN, null)
        val clientId = prefs.getString(AppConstants.KEY_SPOTIFY_CLIENT_ID, null)

        // Get current track
        stage = LikeJobStage.READING_TRACK
        var track = currentTrack(accessToken)
        if (track == null && !refreshToken.isNullOrBlank() && !clientId.isNullOrBlank()) {
            // 401 retry
            val refreshed = refreshAccessToken(refreshToken, clientId)
            if (refreshed != null && refreshed.accessToken.isNotBlank()) {
                accessToken = refreshed.accessToken
                prefs.edit()
                    .putString(AppConstants.KEY_SPOTIFY_ACCESS_TOKEN, accessToken)
                    .apply()
                track = currentTrack(accessToken)
            }
        }

        if (track == null) {
            log("Like skipped: no currently playing track", actionType = "like_track", result = "failure")
            playFeedbackTone(success = false)
            return Result.success()
        }

        val token = accessToken
        if (token.isNullOrBlank()) {
            // The one failure tone that used to play with nothing logged at all.
            log("Like skipped: no access token after refresh", actionType = "like_track", result = "failure")
            playFeedbackTone(success = false)
            return Result.success()
        }
        likeToken = token
        pressId?.let { UndoJournal.setTrack(prefs, it, track.id, track.uri) }

        val ruleConfig = loadRuleConfig(prefs)

        // Skip if this track was liked within the cooldown window
        if (ruleConfig.likeCooldownEnabled && isWithinCooldown(prefs, track.id, ruleConfig.likeCooldownMinutes)) {
            log(
                "Like skipped: track liked recently (cooldown)",
                actionType = "like_track",
                targetId = track.id,
                result = "info"
            )
            playFeedbackTone(success = true)
            return Result.success()
        }

        // Like the track, wherever the user wants likes to go
        stage = LikeJobStage.LIKING
        val liked = runLikeLegs(prefs, token, track, ruleConfig)
        if (liked) stage = LikeJobStage.RECORDING_LIKE
        playFeedbackTone(success = liked)
        if (!liked) return Result.success()
        likedAt = System.currentTimeMillis()
        val previousLikedAt = LocalCounters.lastLikedAt(prefs, track.id)
        recordLikedAt(prefs, track.id)
        journal(UndoLeg.CooldownStamp(previousLikedAt))

        stage = LikeJobStage.EXTRA_ACTIONS
        runArchiveLeg(prefs, token, track, ruleConfig)
        // The legs an undo can revert are all in; a repeat that came in
        // meanwhile is answered now, and an undone like earns no counters.
        if (closePress(prefs)) return Result.success()
        runRulePipeline(prefs, token, track, ruleConfig)

        return Result.success()
    }

    private fun journal(leg: UndoLeg) {
        pressId?.let { UndoJournal.recordLeg(prefs(), it, leg) }
    }

    /**
     * Closes this job's journal entry, once: from here a repeat of the
     * trigger undoes the like instead of queueing. Runs a queued undo inline
     * and returns true when one ran (or found nothing to revert).
     */
    private fun closePress(prefs: SharedPreferences): Boolean {
        val id = pressId ?: return false
        if (pressClosed) return false
        pressClosed = true
        return when (UndoJournal.finishLike(prefs, id, likedAt ?: System.currentTimeMillis())) {
            UndoJournal.Finish.NONE -> false
            UndoJournal.Finish.RUN_UNDO -> {
                runUndoGuarded(prefs, id) { likeToken ?: accessToken(prefs) }
                true
            }
            UndoJournal.Finish.UNDO_NOTHING -> {
                runCatching {
                    log("Undo: the like had nothing to revert", actionType = "undo", result = "info")
                    FeedbackPlayer.play(applicationContext, FeedbackKind.UNDO)
                }
                true
            }
        }
    }

    /** A job [enqueueUndo] queued: undo the like journalled under [pressId]. */
    private fun runUndoJob(): Result {
        val id = pressId
        if (id == null) {
            runCatching {
                log("Undo skipped: no like to undo was named", actionType = "undo", result = "failure")
                FeedbackPlayer.play(applicationContext, FeedbackKind.ERROR)
            }
            return Result.success()
        }
        val prefs = prefs()
        runUndoGuarded(prefs, id) { accessToken(prefs) }
        return Result.success()
    }

    /**
     * [runUndo], reporting a throw the way [doWork] reports one for a like:
     * a line naming it, the error tone, and the entry closed so the next
     * press likes again.
     */
    private fun runUndoGuarded(prefs: SharedPreferences, id: String, token: () -> String?) {
        try {
            runUndo(prefs, id, token())
        } catch (t: Throwable) {
            runCatching {
                log(
                    "Undo failed: ${t.javaClass.simpleName}: ${t.message ?: "no message"}",
                    actionType = "undo",
                    result = "failure"
                )
                FeedbackPlayer.play(applicationContext, FeedbackKind.ERROR)
            }
            runCatching { UndoJournal.finishUndo(prefs, id) }
        }
    }

    /**
     * Reverts every leg the like [id] journalled, newest first, and closes the
     * entry so the next press likes again. One failed leg does not stop the
     * others; the log names each one that failed.
     */
    private fun runUndo(prefs: SharedPreferences, id: String, token: String?) {
        val entry = UndoJournal.entry(prefs, id)
        if (entry == null) {
            log("Undo failed: the like is no longer in the journal", actionType = "undo", result = "failure")
            FeedbackPlayer.play(applicationContext, FeedbackKind.ERROR)
            return
        }
        val result = UndoRunner.run(entry, undoOps(prefs, token))
        UndoJournal.finishUndo(prefs, id)
        if (result.succeeded) {
            log(
                "Undid like of ${entry.trackId}: " + entry.legs.joinToString { UndoRunner.legName(it) },
                actionType = "undo",
                targetId = entry.trackId,
                result = "success"
            )
            FeedbackPlayer.play(applicationContext, FeedbackKind.UNDO)
        } else {
            log(
                "Undo failed on " + result.failures.joinToString("; ") { "${it.leg} (${it.reason})" },
                actionType = "undo",
                targetId = entry.trackId,
                result = "failure"
            )
            FeedbackPlayer.play(applicationContext, FeedbackKind.ERROR)
        }
    }

    private fun undoOps(prefs: SharedPreferences, token: String?): UndoRunner.Ops = object : UndoRunner.Ops {
        private fun token(): String =
            token?.takeIf { it.isNotBlank() } ?: throw IllegalStateException("no Spotify access token")

        override fun unsave(trackUri: String): ApiResult {
            val t = token()
            val id = URLEncoder.encode(trackUri.substringAfterLast(':'), Charsets.UTF_8.name())
            return SpotifyLibraryWrite.removeFromLibrary(
                trackUri,
                generic = { url -> api(url, t, "DELETE") },
                legacy = { api("https://api.spotify.com/v1/me/tracks?ids=$id", t, "DELETE") }
            )
        }

        override fun countInPlaylist(playlistId: String, trackId: String): Int =
            this@SpotifyLikeWorker.countInPlaylist(prefs, playlistId, trackId, token())

        override fun removeAll(playlistId: String, trackUri: String): ApiResult =
            removeTrackFromPlaylist(playlistId, trackUri, token())

        override fun add(playlistId: String, trackUri: String): ApiResult =
            addTrackToPlaylist(playlistId, trackUri, token())

        override fun forgetPromoted(trackId: String) =
            LocalCounters.forgetPromoted(prefs, trackId)

        override fun forgetArtistTrack(artistId: String, trackId: String) =
            LocalCounters.forgetArtistTrack(prefs, artistId, trackId)

        override fun clearArtistTrackRow(sheet: LikeCounter.Target, artistId: String, trackId: String): String? =
            LikeCounter.clearArtistTrack(prefs, sheet, artistId, trackId)

        override fun unfollow(artistId: String): ApiResult {
            val t = token()
            val id = URLEncoder.encode(artistId, Charsets.UTF_8.name())
            return SpotifyLibraryWrite.removeFromLibrary(
                SpotifyLibraryEndpoints.artistUri(artistId),
                generic = { url -> api(url, t, "DELETE") },
                legacy = { api("https://api.spotify.com/v1/me/following?type=artist&ids=$id", t, "DELETE") }
            )
        }

        override fun forgetFollowed(artistId: String) =
            LocalCounters.forgetFollowed(prefs, artistId)

        override fun restoreLikedAt(trackId: String, previous: Long?) =
            LocalCounters.restoreLikedAt(prefs, trackId, previous)

        override fun decrementSheetCount(target: LikeCounter.Target, trackId: String): LikeCounter.CountOutcome =
            LikeCounter.decrement(prefs, target, trackId)

        override fun decrementLocalCount(trackId: String) {
            LocalCounters.decrement(prefs, LocalCounters.Kind.TRACK, trackId)
        }
    }

    /**
     * Sends the like itself, on whichever legs the destination asks for, and
     * logs each one. Returns whether the like counted as a success -- with
     * `both`, one leg is enough, so a half failure is logged but still leaves
     * the song liked.
     *
     * The branching lives in [LikeDestination] so this worker, the Dart
     * Spotify path and the YouTube Music liker cannot drift apart.
     */
    private fun runLikeLegs(
        prefs: SharedPreferences,
        token: String,
        track: CurrentTrack,
        ruleConfig: RuleConfig
    ): Boolean {
        var nativeOk = false
        if (ruleConfig.likeDestination.likesNatively) {
            // Asked first so an undo never unsaves a track the user had saved
            // themselves. No readable answer counts as saved: the undo then
            // leaves the save alone, the safe way to be wrong.
            val wasSaved = pressId?.let { savedInLibrary(track.uri, token) }
            if (pressId != null && wasSaved == null) {
                log(
                    "Could not tell whether ${track.id} was already saved; an undo will keep the save",
                    actionType = "like_track",
                    targetId = track.id,
                    result = "info"
                )
            }
            val result = likeTrack(track.id, token)
            nativeOk = result.success
            if (result.success) journal(UndoLeg.NativeSave(alreadySaved = wasSaved != false))
            if (result.success) {
                log(
                    "Liked track: ${track.id}",
                    actionType = "like_track",
                    targetId = track.id,
                    result = "success",
                    httpCode = result.statusCode
                )
            } else {
                log(
                    "Like failed for track: ${track.id}" + (result.errorBody?.let { ": $it" } ?: ""),
                    actionType = "like_track",
                    targetId = track.id,
                    result = "failure",
                    httpCode = result.statusCode
                )
            }
        }

        var playlistOk = false
        if (ruleConfig.likeDestination.addsToPlaylist) {
            val name = ruleConfig.likePlaylistName
            // Three different things used to collapse into one "failed" line:
            // no playlist name configured, a playlist that could be neither
            // found nor created, and a throw on the way. Name which one.
            var reason: String? = null
            var recovered = false
            val outcome = runCatching {
                if (name.isBlank()) {
                    reason = "no playlist name configured"
                    return@runCatching ApiResult(false, 0)
                }
                val playlistId = ensurePlaylist(prefs, name, token)
                if (playlistId == null) {
                    reason = "playlist not found and could not be created"
                    return@runCatching ApiResult(false, 0)
                }
                val first = addTrackToPlaylist(playlistId, track.uri, token)
                if (first.success) journal(UndoLeg.LikePlaylistAdd(playlistId))
                if (first.statusCode != 404) return@runCatching first

                // The cached id names a playlist that no longer exists -- the
                // user deleted it. Dropping the entry is what makes the second
                // resolve real: a deleted playlist never comes back in the
                // listing, so with the entry still there the lookup would hand
                // back the same dead id. Without it, the resolve enumerates and
                // then creates. Exactly one retry, never a loop.
                PlaylistCache.forget(prefs, name)
                val freshId = ensurePlaylist(prefs, name, token)
                if (freshId == null) {
                    reason = "404, and the playlist could not be found or recreated"
                    return@runCatching ApiResult(false, 404)
                }
                val retried = addTrackToPlaylist(freshId, track.uri, token)
                if (retried.success) journal(UndoLeg.LikePlaylistAdd(freshId))
                if (retried.success) recovered = true
                else reason = "404 on the cached playlist, retry also failed"
                retried
            }.getOrElse {
                reason = "${it.javaClass.simpleName}: ${it.message ?: "no message"}"
                ApiResult(false, 0)
            }
            playlistOk = outcome.success
            if (outcome.success) {
                log(
                    "Added to like playlist: $name" +
                        if (recovered) " (after clearing a stale playlist id)" else "",
                    actionType = "like_playlist_add",
                    targetId = track.id,
                    result = "success",
                    httpCode = outcome.statusCode
                )
            } else {
                log(
                    "Adding to like playlist failed: ${name.ifBlank { "(unnamed)" }}" +
                        (reason?.let { " ($it)" } ?: "") +
                        (outcome.errorBody?.let { ": $it" } ?: ""),
                    actionType = "like_playlist_add",
                    targetId = track.id,
                    result = "failure",
                    httpCode = outcome.statusCode.takeIf { it > 0 }
                )
            }
        }

        return LikeDestination.succeeded(ruleConfig.likeDestination, nativeOk, playlistOk)
    }

    /**
     * Takes the track out of the archive playlist, non-blocking. A journalled
     * press counts the copies first: Spotify removes every copy of a URI, and
     * the undo puts back exactly as many. When they cannot be counted the
     * removal is skipped rather than made unrevertable.
     */
    private fun runArchiveLeg(prefs: SharedPreferences, token: String, track: CurrentTrack, ruleConfig: RuleConfig) {
        if (ruleConfig.archiveRemoveEnabled && ruleConfig.archivePlaylistName.isNotBlank()) {
            runCatching {
                val archiveId = findPlaylistByName(prefs, ruleConfig.archivePlaylistName, token)
                if (archiveId != null) {
                    val copies = if (pressId == null) null else try {
                        countInPlaylist(prefs, archiveId, track.id, token, ruleConfig.archivePlaylistName)
                    } catch (t: Exception) {
                        log(
                            "Archive removal skipped: could not count the copies to put back on undo " +
                                "(${t.javaClass.simpleName}: ${t.message ?: "no message"})",
                            actionType = "archive_remove",
                            targetId = track.id,
                            result = "failure"
                        )
                        return@runCatching
                    }
                    if (copies == 0) return@runCatching
                    val result = removeTrackFromPlaylist(archiveId, track.uri, token)
                    if (result.success && copies != null) journal(UndoLeg.ArchiveRemove(archiveId, copies))
                    // Same stale-cache trap as the like leg, minus the retry:
                    // this leg is non-blocking, so dropping the dead id is
                    // enough -- the next press resolves it properly instead of
                    // waiting out the cache TTL.
                    if (result.statusCode == 404) PlaylistCache.forget(prefs, ruleConfig.archivePlaylistName)
                    if (result.success) {
                        log(
                            "Removed from archive playlist: ${ruleConfig.archivePlaylistName}",
                            actionType = "archive_remove",
                            targetId = track.id,
                            result = "success",
                            httpCode = result.statusCode
                        )
                    } else {
                        log(
                            "Archive removal failed",
                            actionType = "archive_remove",
                            targetId = track.id,
                            result = "failure",
                            httpCode = result.statusCode
                        )
                    }
                }
            }.onFailure {
                log(
                    "Archive removal failed: ${it.message}",
                    actionType = "archive_remove",
                    targetId = track.id,
                    result = "failure"
                )
            }
        }
    }

    private fun runRulePipeline(prefs: SharedPreferences, token: String, track: CurrentTrack, ruleConfig: RuleConfig) {
        val trackCount = countTrackLike(prefs, token, track.id)
        if (ruleConfig.bestEnabled && ruleConfig.bestPlaylistName.isNotBlank()) {
            val bestName = ruleConfig.bestPlaylistName
            runCatching {
                // At or past the threshold, once per track, never a second
                // copy: BestPromotion holds that rule and its tests (#245).
                var bestId: String? = null
                var addResult: ApiResult? = null
                val outcome = BestPromotion.run(
                    prefs,
                    trackCount,
                    ruleConfig.bestThreshold,
                    track.id,
                    isInPlaylist = {
                        val id = ensurePlaylist(prefs, bestName, token)
                        bestId = id
                        id != null && playlistContainsTrack(prefs, bestName, id, track.id, token)
                    },
                    add = {
                        val id = bestId
                        if (id == null) {
                            false
                        } else {
                            val result = addTrackToPlaylist(id, track.uri, token)
                            if (result.statusCode == 404) PlaylistCache.forget(prefs, bestName)
                            addResult = result
                            result.success
                        }
                    },
                )
                when (outcome) {
                    BestPromotion.Outcome.NOT_DUE -> Unit
                    BestPromotion.Outcome.ADDED -> log(
                        "Added to best playlist: $bestName",
                        actionType = "best_add",
                        targetId = track.id,
                        result = "success",
                        httpCode = addResult?.statusCode
                    )
                    BestPromotion.Outcome.ALREADY_IN_PLAYLIST -> log(
                        "Already in best playlist: $bestName",
                        actionType = "best_add",
                        targetId = track.id,
                        result = "info"
                    )
                    BestPromotion.Outcome.NOT_ADDED -> log(
                        if (bestId == null) {
                            "Best promotion failed: no playlist named \"$bestName\" and creating one failed"
                        } else {
                            "Best promotion failed"
                        },
                        actionType = "best_add",
                        targetId = track.id,
                        result = "failure",
                        httpCode = addResult?.statusCode
                    )
                }
                // Only the press that promoted the track hands the undo a
                // best leg; one that found it already there leaves it (#273).
                BestPromotion.undoLeg(outcome, bestId)?.let { journal(it) }
            }.onFailure {
                log(
                    "Best promotion failed: ${it.message}",
                    actionType = "best_add",
                    targetId = track.id,
                    result = "failure"
                )
            }
        }

        // Every artist on the track, not just the first: a feature or a
        // collaboration is as much a like for the guest as for the headliner,
        // which is how the Dart and desktop halves have always counted it.
        track.artistIds.forEach { artistId ->
            // The like tally backs the stats screen, so it moves either way.
            // The follow decision counts distinct tracks: the shared sheet's
            // when there is one, else this device's -- never likes (#243).
            LocalCounters.increment(prefs, LocalCounters.Kind.ARTIST, artistId)
            if (!ruleConfig.followArtistEnabled) return@forEach
            // A track this press added to the artist's tally is handed to
            // the undo; one the tally already held is not (#273).
            val artistCount = LocalCounters.artistFollowCount(
                prefs,
                artistId,
                track.id,
                onAdded = { journal(UndoLeg.ArtistTrack(artistId)) },
            ) {
                sharedArtistTrackCount(prefs, token, artistId, track.id)
            }
            val shouldFollow = LocalCounters.shouldFollow(
                artistCount,
                ruleConfig.followArtistThreshold,
                LocalCounters.followedArtists(prefs),
                artistId,
            )
            if (!shouldFollow) return@forEach
            runCatching {
                // Asked first so an undo never unfollows an artist the user
                // followed themselves. No readable answer counts as followed.
                val wasFollowing = pressId?.let { followingArtist(artistId, token) }
                if (pressId != null && wasFollowing == null) {
                    log(
                        "Could not tell whether $artistId was already followed; an undo will keep the follow",
                        actionType = "follow_artist",
                        targetId = artistId,
                        result = "info"
                    )
                }
                val result = followArtist(artistId, token)
                if (result.success) {
                    LocalCounters.markArtistFollowed(prefs, artistId)
                    journal(UndoLeg.ArtistFollow(artistId, alreadyFollowed = wasFollowing != false))
                    log(
                        "Auto-followed artist: $artistId",
                        actionType = "follow_artist",
                        targetId = artistId,
                        result = "success",
                        httpCode = result.statusCode
                    )
                } else {
                    log(
                        "Follow artist failed" + (result.errorBody?.let { ": $it" } ?: ""),
                        actionType = "follow_artist",
                        targetId = artistId,
                        result = "failure",
                        httpCode = result.statusCode
                    )
                }
            }.onFailure {
                log(
                    "Follow artist failed: ${it.message}",
                    actionType = "follow_artist",
                    targetId = artistId,
                    result = "failure"
                )
            }
        }
    }

    // ---- Rule config -------------------------------------------------

    // The Flutter layer pushes the full config (setRuleConfig) on every app
    // start, so these fallbacks only apply before the app has ever run. They
    // match the fresh-install defaults: extra actions are opt-in, and an action
    // without a playlist name is skipped rather than guessed.
    private fun loadRuleConfig(prefs: SharedPreferences): RuleConfig {
        return RuleConfig(
            archiveRemoveEnabled = prefs.getBoolean(AppConstants.KEY_RULE_ARCHIVE_REMOVE_ENABLED, false),
            archivePlaylistName = prefs.getString(AppConstants.KEY_RULE_ARCHIVE_PLAYLIST_NAME, null)
                ?.trim().orEmpty(),
            bestEnabled = AppConstants.bestRuleEnabled(prefs),
            bestPlaylistName = AppConstants.bestRulePlaylistName(prefs),
            bestThreshold = AppConstants.bestRuleThreshold(prefs),
            followArtistEnabled = prefs.getBoolean(AppConstants.KEY_RULE_FOLLOW_ARTIST_ENABLED, false),
            followArtistThreshold = prefs.getInt(
                AppConstants.KEY_RULE_FOLLOW_ARTIST_THRESHOLD,
                AppConstants.DEFAULT_FOLLOW_ARTIST_THRESHOLD
            ).takeIf { it >= 1 } ?: AppConstants.DEFAULT_FOLLOW_ARTIST_THRESHOLD,
            likeCooldownEnabled = prefs.getBoolean(AppConstants.KEY_RULE_LIKE_COOLDOWN_ENABLED, true),
            likeCooldownMinutes = prefs.getInt(
                AppConstants.KEY_RULE_LIKE_COOLDOWN_MINUTES,
                AppConstants.DEFAULT_LIKE_COOLDOWN_MINUTES
            ).takeIf { it >= 0 } ?: AppConstants.DEFAULT_LIKE_COOLDOWN_MINUTES,
            likeDestination = AppConstants.likeRuleDestination(prefs),
            likePlaylistName = AppConstants.likeRulePlaylistName(prefs)
        )
    }

    // ---- Like counting -------------------------------------------------

    /**
     * Counts the like on the shared Sheet or, failing that, on this device,
     * and journals which counter took it, so an undo lowers that one (#272).
     * The choice is [TrackCounting]'s; this supplies the calls.
     *
     * The track counter runs after [closePress], so a repeat can already have
     * turned the entry to [UndoJournal.State.UNDOING]. The leg still reaches
     * the undo: the undo job is queued on this job's unique work with
     * APPEND_OR_REPLACE, so it starts only once this like job has finished.
     */
    private fun countTrackLike(prefs: SharedPreferences, token: String, trackId: String): Int =
        TrackCounting.count(object : TrackCounting.Ops {
            override fun target(): LikeCounter.Target? {
                // The shared sheet keys its rows by Spotify user id, and nothing on
                // the like path used to fetch one: the id was a side effect of
                // creating a playlist. With the extra rules off -- the default -- it
                // was never there, so every like fell through to the local count and
                // the user's sheet stayed empty with nothing to say why.
                getCurrentUserId(prefs, token)
                return LikeCounter.target(prefs, MusicProvider.SPOTIFY)
            }

            override fun incrementSheet(target: LikeCounter.Target) =
                LikeCounter.increment(prefs, target, trackId)

            override fun incrementLocal() =
                LocalCounters.increment(prefs, LocalCounters.Kind.TRACK, trackId)

            override fun journal(leg: UndoLeg.TrackCount) = this@SpotifyLikeWorker.journal(leg)

            override fun sheetRefused(outcome: LikeCounter.CountOutcome) {
                // The like itself went through; only the shared count did not. Say
                // which, because "counted here only" with no reason sent users
                // looking for a sign-in problem they did not have (#200).
                log(
                    "Like counted on this device only: ${outcome.failure}",
                    actionType = "like_count",
                    targetId = trackId,
                    result = "failure",
                    httpCode = outcome.httpCode
                )
            }
        })

    /**
     * How many distinct tracks by [artistId] this Spotify account has liked
     * on any device, off the shared sheet's ArtistTracks tab, with [trackId]
     * recorded first. Null when no counter is configured or the sheet did not
     * answer — the caller then decides on this device's own count, and a
     * failure says so on the Logs screen.
     */
    private fun sharedArtistTrackCount(
        prefs: SharedPreferences,
        token: String,
        artistId: String,
        trackId: String,
    ): Int? {
        getCurrentUserId(prefs, token)
        val target = LikeCounter.target(prefs, MusicProvider.SPOTIFY) ?: return null
        val outcome = LikeCounter.recordArtistTrack(prefs, target, artistId, trackId) {
            journal(UndoLeg.ArtistTrackRow(artistId, target))
        }
        outcome.count?.let { return it }
        log(
            "Artist like counted on this device only: ${outcome.failure}",
            actionType = "follow_artist",
            targetId = artistId,
            result = "failure",
            httpCode = outcome.httpCode
        )
        return null
    }

    // ---- Like cooldown -------------------------------------------------

    private fun isWithinCooldown(prefs: SharedPreferences, trackId: String, cooldownMinutes: Int): Boolean {
        val last = LocalCounters.lastLikedAt(prefs, trackId) ?: return false
        val elapsedMs = System.currentTimeMillis() - last
        return elapsedMs < cooldownMinutes * 60_000L
    }

    private fun recordLikedAt(prefs: SharedPreferences, trackId: String) {
        LocalCounters.recordLikedAt(prefs, trackId, System.currentTimeMillis())
    }

    // ---- Playlist lookup / creation -------------------------------------------------

    private fun findPlaylistByName(prefs: SharedPreferences, name: String, token: String): String? {
        val cache = PlaylistCache.load(prefs)
        PlaylistCache.find(cache, name)?.let { return it }

        val limit = 50
        var offset = 0
        while (true) {
            val connection = api("https://api.spotify.com/v1/me/playlists?limit=$limit&offset=$offset", token, "GET")
            if (connection.responseCode !in 200..299) break
            val payload = readBody(connection) ?: break
            val json = JSONObject(payload)
            val items = json.optJSONArray("items") ?: break

            var found: String? = null
            for (i in 0 until items.length()) {
                val playlist = items.optJSONObject(i) ?: continue
                val playlistName = playlist.optString("name")
                val playlistId = playlist.optString("id")
                if (playlistName.isBlank() || playlistId.isBlank()) continue
                cache.put(playlistName, playlistId)
                if (found == null && playlistName.equals(name, ignoreCase = true)) found = playlistId
            }
            PlaylistCache.save(prefs, cache)
            if (found != null) return found

            val total = json.optInt("total", items.length())
            offset += limit
            if (items.length() < limit || offset >= total) break
        }
        return null
    }

    private fun ensurePlaylist(prefs: SharedPreferences, name: String, token: String): String? {
        findPlaylistByName(prefs, name, token)?.let { return it }

        val userId = getCurrentUserId(prefs, token) ?: return null
        val body = JSONObject()
            .put("name", name)
            .put("public", false)
            .put("description", "Managed by Like Current Song")
            .toString()

        // Invalidate the cache before creating so a concurrent rebuild can't miss the new playlist.
        PlaylistCache.save(prefs, JSONObject())

        val connection = apiWithBody("https://api.spotify.com/v1/users/$userId/playlists", token, "POST", body)
        if (connection.responseCode !in 200..299) return null
        val payload = readBody(connection) ?: return null
        val id = JSONObject(payload).optString("id").takeIf { it.isNotBlank() } ?: return null

        val cache = PlaylistCache.load(prefs)
        cache.put(name, id)
        PlaylistCache.save(prefs, cache)
        return id
    }

    private fun getCurrentUserId(prefs: SharedPreferences, token: String): String? {
        prefs.getString(AppConstants.KEY_SPOTIFY_USER_ID, null)?.takeIf { it.isNotBlank() }?.let { return it }
        val connection = api("https://api.spotify.com/v1/me", token, "GET")
        if (connection.responseCode !in 200..299) return null
        val payload = readBody(connection) ?: return null
        val id = JSONObject(payload).optString("id").takeIf { it.isNotBlank() } ?: return null
        prefs.edit().putString(AppConstants.KEY_SPOTIFY_USER_ID, id).apply()
        return id
    }

    /**
     * Whether [trackId] is in the playlist [playlistId] (named [name]) already,
     * paging through all of it. Throws when Spotify refuses a page, so the
     * caller logs the failure and remembers nothing; a 404 also drops the
     * cached id, as the add does.
     */
    private fun playlistContainsTrack(
        prefs: SharedPreferences,
        name: String,
        playlistId: String,
        trackId: String,
        token: String,
    ): Boolean = playlistPages(prefs, name, playlistId, token).any { trackId in it.trackIds }

    /** How many copies of [trackId] the playlist holds, over every page. */
    private fun countInPlaylist(
        prefs: SharedPreferences,
        playlistId: String,
        trackId: String,
        token: String,
        name: String? = null,
    ): Int = playlistPages(prefs, name, playlistId, token).sumOf { it.copies[trackId] ?: 0 }

    /**
     * The playlist's pages, read lazily. Throws on an unreadable page; a 404
     * also drops the cached id of the playlist [name], when one is given.
     */
    private fun playlistPages(
        prefs: SharedPreferences,
        name: String?,
        playlistId: String,
        token: String,
    ): Sequence<SpotifyPlaylistTracks.Page> = sequence {
        var url: String? = SpotifyPlaylistTracks.firstPageUrl(playlistId)
        while (url != null) {
            val connection = api(url, token, "GET")
            val code = connection.responseCode
            if (code !in 200..299) {
                if (code == 404 && name != null) PlaylistCache.forget(prefs, name)
                throw IllegalStateException("reading the playlist failed with HTTP $code")
            }
            val body = readBody(connection) ?: throw IllegalStateException("reading the playlist returned no body")
            val page = SpotifyPlaylistTracks.parsePage(body)
            yield(page)
            url = page.next
        }
    }

    private fun addTrackToPlaylist(playlistId: String, trackUri: String, token: String): ApiResult {
        val body = JSONObject().put("uris", JSONArray().put(trackUri)).toString()
        val connection = apiWithBody("https://api.spotify.com/v1/playlists/$playlistId/tracks", token, "POST", body)
        val code = connection.responseCode
        return ApiResult(code in 200..299, code)
    }

    private fun removeTrackFromPlaylist(playlistId: String, trackUri: String, token: String): ApiResult {
        val track = JSONObject().put("uri", trackUri)
        val body = JSONObject().put("tracks", JSONArray().put(track)).toString()
        val connection = apiWithBody("https://api.spotify.com/v1/playlists/$playlistId/tracks", token, "DELETE", body)
        val code = connection.responseCode
        return ApiResult(code in 200..299, code)
    }

    private fun followArtist(artistId: String, token: String): ApiResult {
        return saveToLibrary(SpotifyLibraryEndpoints.artistUri(artistId), token) {
            val encoded = URLEncoder.encode(artistId, Charsets.UTF_8.name())
            api("https://api.spotify.com/v1/me/following?type=artist&ids=$encoded", token, "PUT")
        }
    }

    /**
     * Saves/follows [uri] through the generic `PUT /me/library` endpoint, with
     * one fallback to [legacy]. The decision itself lives in
     * [SpotifyLibraryWrite.saveToLibrary], which is free of Android APIs and
     * therefore unit-tested; this only supplies the connections.
     */
    private fun saveToLibrary(
        uri: String,
        token: String,
        legacy: () -> HttpURLConnection
    ): ApiResult = SpotifyLibraryWrite.saveToLibrary(
        uri,
        generic = { url -> api(url, token, "PUT") },
        legacy = legacy
    )

    // ---- Core like + track lookup -------------------------------------------------

    private fun currentTrack(token: String?): CurrentTrack? {
        if (token.isNullOrBlank()) return null
        val connection = api("https://api.spotify.com/v1/me/player/currently-playing", token, "GET")
        val code = connection.responseCode
        if (code == 204 || code !in 200..299) return null
        val payload = readBody(connection) ?: return null
        val item = JSONObject(payload).optJSONObject("item") ?: return null
        val id = item.optString("id")
        if (id.isBlank()) return null
        val uri = item.optString("uri").ifBlank { "spotify:track:$id" }
        return CurrentTrack(id = id, uri = uri, artistIds = artistIds(item))
    }

    /** Every artist credited on a track item, in order, skipping any without an id. */
    private fun artistIds(item: JSONObject): List<String> {
        val artists = item.optJSONArray("artists") ?: return emptyList()
        val ids = ArrayList<String>(artists.length())
        for (i in 0 until artists.length()) {
            artists.optJSONObject(i)?.optString("id")?.takeIf { it.isNotBlank() }?.let { ids.add(it) }
        }
        return ids
    }

    /** Whether [uri] is in the library already; null when that cannot be told. */
    private fun savedInLibrary(uri: String, token: String): Boolean? = runCatching {
        val trackId = URLEncoder.encode(uri.substringAfterLast(':'), Charsets.UTF_8.name())
        SpotifyLibraryWrite.contains(
            uri,
            generic = { url -> api(url, token, "GET") },
            legacy = { api("https://api.spotify.com/v1/me/tracks/contains?ids=$trackId", token, "GET") }
        )
    }.getOrNull()

    /** Whether [artistId] is followed already; null when that cannot be told. */
    private fun followingArtist(artistId: String, token: String): Boolean? = runCatching {
        val encoded = URLEncoder.encode(artistId, Charsets.UTF_8.name())
        SpotifyLibraryWrite.contains(
            SpotifyLibraryEndpoints.artistUri(artistId),
            generic = { url -> api(url, token, "GET") },
            legacy = { api("https://api.spotify.com/v1/me/following/contains?type=artist&ids=$encoded", token, "GET") }
        )
    }.getOrNull()

    private fun likeTrack(trackId: String, token: String?): ApiResult {
        if (token.isNullOrBlank()) return ApiResult(false, 0)
        return saveToLibrary(SpotifyLibraryEndpoints.trackUri(trackId), token) {
            val encodedTrackId = URLEncoder.encode(trackId, Charsets.UTF_8.name())
            api("https://api.spotify.com/v1/me/tracks?ids=$encodedTrackId", token, "PUT")
        }
    }

    private fun refreshAccessToken(refreshToken: String, clientId: String): RefreshedToken? {
        val connection = URL("https://accounts.spotify.com/api/token").openConnection() as HttpURLConnection
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        // Same budget as [api]: without it a stalled refresh holds the worker
        // open until WorkManager's own 10-minute ceiling kills it.
        connection.connectTimeout = 10000
        connection.readTimeout = 10000

        val body = buildString {
            append("grant_type=refresh_token")
            append("&refresh_token=")
            append(URLEncoder.encode(refreshToken, Charsets.UTF_8.name()))
            append("&client_id=")
            append(URLEncoder.encode(clientId, Charsets.UTF_8.name()))
        }
        OutputStreamWriter(connection.outputStream).use { it.write(body) }

        val statusCode = connection.responseCode
        if (statusCode !in 200..299) return null
        val payload = readBody(connection) ?: return null
        val json = JSONObject(payload)
        val access = json.optString("access_token")
        if (access.isBlank()) return null
        return RefreshedToken(
            accessToken = access,
            refreshToken = json.optString("refresh_token").ifBlank { null },
            expiresInSec = if (json.has("expires_in")) json.optLong("expires_in", 0L).takeIf { it > 0L } else null
        )
    }

    // ---- HTTP plumbing -------------------------------------------------

    private fun api(url: String, token: String, method: String): HttpURLConnection {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.requestMethod = method
        connection.setRequestProperty("Authorization", "Bearer $token")
        connection.connectTimeout = 10000
        connection.readTimeout = 10000
        if (method == "PUT") connection.doOutput = true
        return connection
    }

    private fun apiWithBody(url: String, token: String, method: String, body: String): HttpURLConnection {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.requestMethod = method
        connection.setRequestProperty("Authorization", "Bearer $token")
        connection.setRequestProperty("Content-Type", "application/json")
        connection.connectTimeout = 10000
        connection.readTimeout = 10000
        connection.doOutput = true
        OutputStreamWriter(connection.outputStream).use { it.write(body) }
        return connection
    }

    private fun readBody(connection: HttpURLConnection): String? {
        return try {
            BufferedReader(connection.inputStream.reader()).use { it.readText() }
        } catch (_: Exception) {
            null
        }
    }

    private fun playFeedbackTone(success: Boolean) {
        FeedbackPlayer.play(applicationContext, success)
    }

    private fun log(
        message: String,
        actionType: String = "native",
        targetId: String? = null,
        result: String = "info",
        httpCode: Int? = null
    ) {
        BackgroundLog.emit(applicationContext, message, actionType, result, targetId, httpCode)
        val intent = android.content.Intent(AppConstants.ACTION_LOG_EVENT)
            .putExtra(AppConstants.EXTRA_LOG, message)
            .putExtra(AppConstants.EXTRA_LOG_ACTION_TYPE, actionType)
            .putExtra(AppConstants.EXTRA_LOG_RESULT, result)
        if (targetId != null) intent.putExtra(AppConstants.EXTRA_LOG_TARGET_ID, targetId)
        if (httpCode != null) intent.putExtra(AppConstants.EXTRA_LOG_HTTP_CODE, httpCode)
        androidx.localbroadcastmanager.content.LocalBroadcastManager
            .getInstance(applicationContext)
            .sendBroadcast(intent)
    }

    private data class CurrentTrack(
        val id: String,
        val uri: String,
        val artistIds: List<String>
    )

    private data class RuleConfig(
        val archiveRemoveEnabled: Boolean,
        val archivePlaylistName: String,
        val bestEnabled: Boolean,
        val bestPlaylistName: String,
        val bestThreshold: Int,
        val followArtistEnabled: Boolean,
        val followArtistThreshold: Int,
        val likeCooldownEnabled: Boolean,
        val likeCooldownMinutes: Int,
        val likeDestination: LikeDestination,
        val likePlaylistName: String
    )

    data class RefreshedToken(
        val accessToken: String,
        val refreshToken: String?,
        val expiresInSec: Long?
    )

    companion object {
        /** Id of the [MusicProvider] the trigger routed to; see [doWork]. */
        private const val KEY_ROUTED_PROVIDER = "routed_provider"

        /** The [UndoJournal] entry the job runs for (#267). */
        private const val KEY_PRESS_ID = "press_id"

        /** [MODE_UNDO] for an undo job; absent for a like. */
        private const val KEY_MODE = "mode"
        private const val MODE_UNDO = "undo"

        private const val WORK_NAME = "spotify-like-work"

        /**
         * Queues the like journalled under [pressId]. A new like replaces a
         * job still waiting, except an undo ([afterUndo]): replacing that
         * would cancel it, so the like queues behind it instead.
         */
        fun enqueue(context: Context, provider: MusicProvider, pressId: String?, afterUndo: Boolean) {
            val data = workDataOf(KEY_ROUTED_PROVIDER to provider.id, KEY_PRESS_ID to pressId)
            val policy = if (afterUndo) ExistingWorkPolicy.APPEND_OR_REPLACE else ExistingWorkPolicy.REPLACE
            enqueue(context, data, policy)
        }

        /**
         * Queues the undo of the like journalled under [pressId], behind
         * whatever that like still has to do: replacing it would cut its
         * remaining steps short.
         */
        fun enqueueUndo(context: Context, pressId: String) {
            val data = workDataOf(KEY_MODE to MODE_UNDO, KEY_PRESS_ID to pressId)
            enqueue(context, data, ExistingWorkPolicy.APPEND_OR_REPLACE)
        }

        private fun enqueue(context: Context, data: Data, policy: ExistingWorkPolicy) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            val request = OneTimeWorkRequestBuilder<SpotifyLikeWorker>()
                .setConstraints(constraints)
                .setInputData(data)
                .build()

            WorkManager.getInstance(context).enqueueUniqueWork(WORK_NAME, policy, request)
        }
    }
}
