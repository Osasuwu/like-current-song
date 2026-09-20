package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class YouTubeMusicExtraActionsTest {

    // ---- reachedThreshold -------------------------------------------------

    @Test
    fun `the action fires on the like that reaches the threshold`() {
        assertTrue(YouTubeMusicExtraActions.reachedThreshold(count = 3, threshold = 3))
    }

    @Test
    fun `earlier likes leave the song alone`() {
        assertFalse(YouTubeMusicExtraActions.reachedThreshold(count = 1, threshold = 3))
        assertFalse(YouTubeMusicExtraActions.reachedThreshold(count = 2, threshold = 3))
    }

    @Test
    fun `later likes do not fire it again`() {
        // A re-like of an old favourite must not add a second copy to the
        // best-of playlist, however high its count has climbed.
        assertFalse(YouTubeMusicExtraActions.reachedThreshold(count = 4, threshold = 3))
        assertFalse(YouTubeMusicExtraActions.reachedThreshold(count = 99, threshold = 3))
    }

    @Test
    fun `a threshold of one fires on the first like`() {
        assertTrue(YouTubeMusicExtraActions.reachedThreshold(count = 1, threshold = 1))
        assertFalse(YouTubeMusicExtraActions.reachedThreshold(count = 2, threshold = 1))
    }

    // ---- countKey -------------------------------------------------

    @Test
    fun `youtube ids are namespaced apart from spotify ids`() {
        // Both pipelines write the same local count maps.
        val id = "dQw4w9WgXcQ"
        assertEquals("ytmusic:$id", YouTubeMusicExtraActions.countKey(id))
        assertNotEquals(id, YouTubeMusicExtraActions.countKey(id))
    }

    @Test
    fun `different ids keep different counts`() {
        assertNotEquals(
            YouTubeMusicExtraActions.countKey("UC_artist_a"),
            YouTubeMusicExtraActions.countKey("UC_artist_b"),
        )
    }
}
