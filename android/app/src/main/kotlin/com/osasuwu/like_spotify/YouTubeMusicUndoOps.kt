package com.osasuwu.like_spotify

import android.content.SharedPreferences
import org.json.JSONObject
import java.net.URLEncoder

/**
 * What [UndoRunner] reverts a YouTube Music like with (#274): the YouTube
 * Data API for the account, this device's counters for the rest. The
 * journal entry's track id and track "uri" are both the bare video id.
 *
 * Local maps key a video or a channel by [YouTubeMusicExtraActions.countKey],
 * the Sheet by the bare id, as the like itself does.
 *
 * [apiCall] throws [ApiFailure] when the API refuses; each op turns that into
 * the failed [ApiResult] the runner names the leg with. [unrate] takes back a
 * rating set through the player's media session, keyed by the song's
 * cooldown key; [clearRow] and [decrementSheet] reach the counter Sheet.
 */
internal class YouTubeMusicUndoOps(
    private val prefs: SharedPreferences,
    private val apiCall: (method: String, url: String, body: String?) -> String,
    private val unrate: (song: String) -> String? = { "no media session to take the rating back through" },
    private val clearRow: (LikeCounter.Target, String, String) -> String? = { sheet, channelId, videoId ->
        LikeCounter.clearArtistTrack(prefs, sheet, channelId, videoId)
    },
    private val decrementSheet: (LikeCounter.Target, String) -> LikeCounter.CountOutcome = { sheet, videoId ->
        LikeCounter.decrement(prefs, sheet, videoId)
    },
) : UndoRunner.Ops {

    /** The playlist helpers the like used; the undo logs through the runner, not here. */
    private val playlists = YouTubeMusicExtraActions(prefs, apiCall, { _, _, _, _ -> })

    override fun restoreRating(videoId: String, disliked: Boolean): ApiResult = api {
        val rating = if (disliked) "dislike" else "none"
        apiCall("POST", "${YouTubeDataApi.API_BASE}/videos/rate?id=${encode(videoId)}&rating=$rating", null)
    }

    // Every YouTube Music rating leg names its session song or its video, so
    // the journal's track is never rated: it is the search's match, which
    // need not be the video the like rated.
    override fun unsave(trackUri: String): ApiResult =
        ApiResult(success = false, statusCode = 0, errorBody = "a YouTube Music rating recorded without its video")

    // Only the session can take a session rating back: it rated whatever
    // video the player had, and the Data API knows only the search's match,
    // which can be another upload of the song -- one the user may have liked
    // themselves. So a session that has moved on fails the leg (#274).
    override fun unrateInSession(song: String): String? = unrate(song)

    override fun countInPlaylist(playlistId: String, trackId: String): Int =
        playlists.playlistItemIds(playlistId, trackId).size

    // YouTube keeps one playlistItem per copy, so "remove every copy" is one
    // delete per item; the runner puts back the copies that were there before.
    override fun removeAll(playlistId: String, trackUri: String): ApiResult = api {
        playlists.playlistItemIds(playlistId, trackUri).forEach { playlists.deletePlaylistItem(it) }
    }

    override fun add(playlistId: String, trackUri: String): ApiResult =
        api { playlists.insertPlaylistItem(playlistId, trackUri) }

    // The one item the press added. Gone already (the user took it out
    // since): nothing left to take back.
    override fun removeItem(itemId: String): ApiResult = api {
        try {
            playlists.deletePlaylistItem(itemId)
        } catch (failure: ApiFailure) {
            if (failure.httpCode != 404) throw failure
        }
    }

    override fun forgetPromoted(trackId: String) =
        LocalCounters.forgetPromoted(prefs, YouTubeMusicExtraActions.countKey(trackId))

    override fun forgetArtistTrack(artistId: String, trackId: String) =
        LocalCounters.forgetArtistTrack(prefs, YouTubeMusicExtraActions.countKey(artistId), trackId)

    override fun clearArtistTrackRow(sheet: LikeCounter.Target, artistId: String, trackId: String): String? =
        clearRow(sheet, artistId, trackId)

    // The Data API deletes a subscription by its own id, not the channel's.
    // None left means the user unsubscribed since: nothing to take back.
    override fun unfollow(artistId: String): ApiResult = api {
        val body = apiCall(
            "GET",
            "${YouTubeDataApi.API_BASE}/subscriptions?part=id&forChannelId=${encode(artistId)}&mine=true",
            null,
        )
        val items = JSONObject(body).optJSONArray("items")
        for (i in 0 until (items?.length() ?: 0)) {
            val id = items!!.getJSONObject(i).optString("id").takeIf { it.isNotBlank() } ?: continue
            apiCall("DELETE", "${YouTubeDataApi.API_BASE}/subscriptions?id=${encode(id)}", null)
        }
    }

    override fun forgetFollowed(artistId: String) =
        LocalCounters.forgetFollowed(prefs, YouTubeMusicExtraActions.countKey(artistId))

    override fun restoreLikedAt(trackId: String, previous: Long?) =
        LocalCounters.restoreLikedAt(prefs, trackId, previous)

    override fun decrementSheetCount(target: LikeCounter.Target, trackId: String): LikeCounter.CountOutcome =
        decrementSheet(target, trackId)

    override fun decrementLocalCount(trackId: String) {
        LocalCounters.decrement(prefs, LocalCounters.Kind.TRACK, YouTubeMusicExtraActions.countKey(trackId))
    }

    private fun api(call: () -> Unit): ApiResult = try {
        call()
        ApiResult(success = true, statusCode = 200)
    } catch (failure: ApiFailure) {
        ApiResult(success = false, statusCode = failure.httpCode ?: 0, errorBody = failure.outcomeError)
    }

    private fun encode(value: String): String = URLEncoder.encode(value, Charsets.UTF_8.name())
}
