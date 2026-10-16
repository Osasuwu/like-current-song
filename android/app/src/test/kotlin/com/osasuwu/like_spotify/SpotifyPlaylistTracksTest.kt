package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SpotifyPlaylistTracksTest {

    @Test
    fun `the first page asks for the track ids only, 100 at a time`() {
        assertEquals(
            "https://api.spotify.com/v1/playlists/pl1/tracks?limit=100&fields=items(track(id)),next",
            SpotifyPlaylistTracks.firstPageUrl("pl1"),
        )
    }

    @Test
    fun `a page yields its track ids and the next page`() {
        val next = "https://api.spotify.com/v1/playlists/pl1/tracks?offset=100&limit=100"
        val page = SpotifyPlaylistTracks.parsePage(
            """{"items":[{"track":{"id":"t1"}},{"track":{"id":"t2"}}],"next":"$next"}"""
        )
        assertEquals(setOf("t1", "t2"), page.trackIds)
        assertEquals(next, page.next)
    }

    @Test
    fun `items without a track are skipped`() {
        // A removed episode comes back as `"track": null`; a local file has no id.
        val page = SpotifyPlaylistTracks.parsePage(
            """{"items":[{"track":null},{"track":{"id":null}},{},{"track":{"id":"t3"}}],"next":null}"""
        )
        assertEquals(setOf("t3"), page.trackIds)
        assertNull(page.next)
    }

    @Test
    fun `a next page off the Spotify API is not followed`() {
        // The caller sends the user's token to it.
        val page = SpotifyPlaylistTracks.parsePage(
            """{"items":[],"next":"https://example.com/v1/playlists/pl1/tracks?offset=100"}"""
        )
        assertNull(page.next)
    }

    @Test
    fun `an unreadable body reads as an empty last page`() {
        val page = SpotifyPlaylistTracks.parsePage("<html>")
        assertEquals(emptySet<String>(), page.trackIds)
        assertNull(page.next)
    }
}
