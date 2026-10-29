package com.osasuwu.like_spotify

import com.osasuwu.like_spotify.YouTubeMusicLiker.Kind
import com.osasuwu.like_spotify.YouTubeMusicLiker.NowPlaying
import com.osasuwu.like_spotify.YouTubeMusicLiker.Outcome
import com.osasuwu.like_spotify.YouTubeMusicLiker.PlaylistLeg
import android.content.SharedPreferences
import org.json.JSONObject
import java.net.URLEncoder

/**
 * The legs of a YouTube Music like and what each journals for its undo
 * (#274): the rating, through the media session or the Data API, the like
 * playlist, and the cooldown stamp. Free of Android APIs other than
 * SharedPreferences, so the journal writes are unit-tested;
 * [YouTubeMusicLiker] reads the session and hands in the HTTP calls.
 *
 * [journal] is null for a like that is not journalled (the app's own
 * button): it records nothing then, and spends no call on the rating the
 * video had before.
 */
internal class YouTubeMusicLikeLegs(
    private val journal: ((UndoLeg) -> Unit)?,
    /** One Data API call; returns the body, throws [ApiFailure] on a refusal. */
    private val apiCall: (method: String, url: String) -> String,
    /** The search match of the song, naming its video; null when there is none. */
    private val resolve: (NowPlaying) -> YouTubeDataApi.Match?,
    /** Whether a YouTube Music account is signed in for the Data API. */
    private val signedIn: () -> Boolean,
    private val log: (message: String, result: String) -> Unit,
    /** Adds the video to the playlist of that name, creating it; returns the playlist and item, or null. */
    private val addToPlaylist: (name: String, videoId: String) -> YouTubeMusicExtraActions.PlaylistAdd?,
) {

    /** How the media session took the thumb-up. */
    enum class Session { LIKED, ALREADY_LIKED, UNSUPPORTED, DID_NOT_STICK }

    /**
     * The service's own like, given what the session did with it: a session
     * rating journals the song the session rated, anything else falls back
     * to the Data API.
     */
    fun native(session: Session, nowPlaying: NowPlaying): Outcome {
        val song = YouTubeMusicLiker.cooldownKey(nowPlaying.title, nowPlaying.artist)
        return when (session) {
            Session.ALREADY_LIKED -> {
                journal?.invoke(UndoLeg.NativeSave(alreadySaved = true, sessionSong = song))
                Outcome(Kind.ALREADY_LIKED, nowPlaying.display)
            }
            Session.LIKED -> {
                journal?.invoke(UndoLeg.NativeSave(alreadySaved = false, sessionSong = song))
                Outcome(Kind.LIKED, nowPlaying.display)
            }
            Session.UNSUPPORTED, Session.DID_NOT_STICK -> api(nowPlaying)
        }
    }

    /**
     * Rates the song's video like through the Data API. A journalled like
     * reads the rating the video had first, so the undo can put it back.
     */
    private fun api(nowPlaying: NowPlaying): Outcome {
        if (!signedIn()) {
            log("Session like unavailable — sign in to YouTube Music for the fallback", "failure")
            return Outcome(Kind.FAILED, nowPlaying.display, error = "sign in to YouTube Music for the fallback")
        }
        return try {
            val videoId = resolve(nowPlaying)?.videoId
                ?: return Outcome(Kind.FAILED, nowPlaying.display, error = "no YouTube match for this song")
            val encoded = URLEncoder.encode(videoId, Charsets.UTF_8.name())
            val before = if (journal != null) ratingBody(encoded) else null
            apiCall("POST", "${YouTubeDataApi.API_BASE}/videos/rate?id=$encoded&rating=like")
            journal?.invoke(apiSaveLeg(videoId, before))
            log("Liked via YouTube Data API: $videoId", "success")
            Outcome(Kind.LIKED, nowPlaying.display)
        } catch (failure: ApiFailure) {
            Outcome(Kind.FAILED, nowPlaying.display, error = failure.outcomeError, httpCode = failure.httpCode)
        } catch (e: Exception) {
            Outcome(Kind.FAILED, nowPlaying.display, error = "network error: ${e.message}")
        }
    }

    /** The `videos.getRating` body for [encodedId], or null when it cannot be read. */
    private fun ratingBody(encodedId: String): String? = try {
        apiCall("GET", "${YouTubeDataApi.API_BASE}/videos/getRating?id=$encodedId")
    } catch (_: Exception) {
        null
    }

    /**
     * Adds the song to the user's like playlist, creating it the first time.
     *
     * Costs a `playlistItems.insert` (50 units) per like, plus the search the
     * song's videoId needs — cached per song, so a repeat like is one write.
     * The result is reported by the caller, not logged here: the leg is part
     * of the like, so it belongs in the like's own line.
     */
    fun playlist(nowPlaying: NowPlaying, playlistName: String): PlaylistLeg = try {
        val match = resolve(nowPlaying)
        if (match == null) {
            PlaylistLeg(false, "no YouTube match for this song")
        } else {
            val added = addToPlaylist(playlistName, match.videoId)
            if (added != null) {
                journal?.invoke(UndoLeg.LikePlaylistAdd(added.playlistId, added.itemId))
                PlaylistLeg(true)
            } else {
                PlaylistLeg(false, "could not find or create \"$playlistName\"")
            }
        }
    } catch (failure: ApiFailure) {
        PlaylistLeg(false, failure.outcomeError, failure.httpCode)
    } catch (e: Exception) {
        PlaylistLeg(false, "network error: ${e.message}")
    }

    companion object {
        /**
         * Stamps the song [key] as liked at [now], for the like cooldown, and
         * journals the stamp it replaced under that key. YouTube Music keeps
         * its cooldown by song, while the entry's track becomes the videoId
         * once a search runs, so the undo must be told which stamp to restore.
         */
        fun stampLiked(prefs: SharedPreferences, key: String, now: Long, journal: (UndoLeg) -> Unit) {
            val previous = LocalCounters.lastLikedAt(prefs, key)
            LocalCounters.recordLikedAt(prefs, key, now)
            journal(UndoLeg.CooldownStamp(previous, key = key))
        }

        /**
         * The rating leg of a Data API like of [videoId], given the
         * `videos.getRating` [ratingBody] read before it. Unrated: the undo
         * takes the like back. Disliked: the undo puts the dislike back. A
         * like already there, or a rating that cannot be read, counts as the
         * user's own: an undo that keeps a like beats one that takes away
         * theirs.
         */
        fun apiSaveLeg(videoId: String, ratingBody: String?): UndoLeg.NativeSave {
            val rating = ratingBody?.let { body ->
                runCatching { JSONObject(body).optJSONArray("items")?.optJSONObject(0)?.optString("rating") }.getOrNull()
            }
            return when (rating) {
                "none" -> UndoLeg.NativeSave(alreadySaved = false, videoId = videoId)
                "dislike" -> UndoLeg.NativeSave(alreadySaved = false, videoId = videoId, disliked = true)
                else -> UndoLeg.NativeSave(alreadySaved = true, videoId = videoId)
            }
        }
    }
}
