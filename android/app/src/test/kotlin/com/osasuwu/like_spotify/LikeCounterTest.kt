package com.osasuwu.like_spotify

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LikeCounterTest {

    // ---- userIdFor -------------------------------------------------

    @Test
    fun `spotify likes are keyed by the spotify user id`() {
        assertEquals(
            "spotify-user",
            LikeCounter.userIdFor(MusicProvider.SPOTIFY, spotifyUserId = "spotify-user", ytmUserSub = "google-sub"),
        )
    }

    @Test
    fun `youtube music likes are keyed by the google sub`() {
        assertEquals(
            "google-sub",
            LikeCounter.userIdFor(MusicProvider.YTMUSIC, spotifyUserId = "spotify-user", ytmUserSub = "google-sub"),
        )
    }

    @Test
    fun `no fallback to the other service's id`() {
        assertNull(LikeCounter.userIdFor(MusicProvider.YTMUSIC, spotifyUserId = "spotify-user", ytmUserSub = null))
        assertNull(LikeCounter.userIdFor(MusicProvider.SPOTIFY, spotifyUserId = null, ytmUserSub = "google-sub"))
    }

    @Test
    fun `a blank id means not signed in`() {
        assertNull(LikeCounter.userIdFor(MusicProvider.YTMUSIC, spotifyUserId = null, ytmUserSub = "  "))
        assertNull(LikeCounter.userIdFor(MusicProvider.SPOTIFY, spotifyUserId = "", ytmUserSub = null))
    }

    // ---- requestBody -------------------------------------------------

    @Test
    fun `body carries user and track ids`() {
        val body = JSONObject(LikeCounter.requestBody("google-sub", "dQw4w9WgXcQ", wasAlreadyLiked = false))
        assertEquals("google-sub", body.getString("p_user_id"))
        assertEquals("dQw4w9WgXcQ", body.getString("p_track_id"))
    }

    @Test
    fun `already-liked flag is sent only when true`() {
        val fresh = JSONObject(LikeCounter.requestBody("u", "t", wasAlreadyLiked = false))
        assertFalse(fresh.has("p_was_already_liked"))

        val already = JSONObject(LikeCounter.requestBody("u", "t", wasAlreadyLiked = true))
        assertTrue(already.getBoolean("p_was_already_liked"))
    }

    // ---- parseCount -------------------------------------------------

    @Test
    fun `parses the bare integer the rpc returns`() {
        assertEquals(3, LikeCounter.parseCount("3"))
        assertEquals(12, LikeCounter.parseCount(" 12\n"))
    }

    @Test
    fun `unparseable reply is no count`() {
        assertNull(LikeCounter.parseCount(null))
        assertNull(LikeCounter.parseCount(""))
        assertNull(LikeCounter.parseCount("{\"message\":\"boom\"}"))
    }
}
