package com.osasuwu.like_spotify

import org.json.JSONObject

/**
 * Reading which tracks a Spotify playlist holds, for the best-playlist
 * membership check ([BestPromotion]). Same request the desktop makes
 * (`_get_playlist_track_ids_sync` in `like_spotify/extensions/spotify`):
 * `GET /v1/playlists/{id}/tracks`, 100 items a page, only the track ids.
 */
object SpotifyPlaylistTracks {

    private const val API_BASE = "https://api.spotify.com/"

    /** One page of a playlist: the track ids on it and the next page's URL, if any. */
    data class Page(val trackIds: Set<String>, val next: String?)

    fun firstPageUrl(playlistId: String): String =
        "${API_BASE}v1/playlists/$playlistId/tracks?limit=100&fields=items(track(id)),next"

    /**
     * Parses a page. Items without a track -- a local file, an episode removed
     * from the catalogue -- are skipped; an unreadable body reads as an empty
     * last page.
     *
     * [Page.next] is only kept when it points back at the Spotify API: the
     * caller sends the user's token to it.
     */
    fun parsePage(body: String): Page {
        val json = runCatching { JSONObject(body) }.getOrNull() ?: return Page(emptySet(), null)
        val ids = LinkedHashSet<String>()
        val items = json.optJSONArray("items")
        if (items != null) {
            for (i in 0 until items.length()) {
                val track = items.optJSONObject(i)?.optJSONObject("track") ?: continue
                // optString turns a JSON null into the string "null".
                if (track.isNull("id")) continue
                val id = track.optString("id")
                if (id.isNotBlank()) ids.add(id)
            }
        }
        val next = json.optString("next").takeIf { it.startsWith(API_BASE) }
        return Page(ids, next)
    }
}
