package com.osasuwu.like_spotify

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [PlaylistCache] against a [FakeSharedPreferences], with no Android runtime.
 * The cases mirror the Dart twin's cache tests in
 * `test/data/spotify/spotify_playlist_service_test.dart` (#189).
 */
class PlaylistCacheTest {

    private val prefs = FakeSharedPreferences()
    private val now = 1_758_499_200_000L

    private fun store(entries: Map<String, String>, writtenAt: Long = now) {
        PlaylistCache.save(prefs, JSONObject(entries), writtenAt)
    }

    @Test
    fun `a cached id is returned, so the worker never enumerates for it`() {
        store(mapOf("Archive" to "pl-archive", "Best" to "pl-best"))

        // findPlaylistByName returns on a hit here, before the listing loop.
        assertEquals("pl-archive", PlaylistCache.find(PlaylistCache.load(prefs, now), "Archive"))
    }

    @Test
    fun `the lookup ignores case`() {
        store(mapOf("Archive" to "pl-archive"))

        assertEquals("pl-archive", PlaylistCache.find(PlaylistCache.load(prefs, now), "aRcHiVe"))
    }

    @Test
    fun `a blank cached id is a miss, not an answer`() {
        store(mapOf("Archive" to ""))

        assertNull(PlaylistCache.find(PlaylistCache.load(prefs, now), "Archive"))
    }

    @Test
    fun `forgetting drops the entry whatever its case and keeps the rest`() {
        store(mapOf("Archive" to "pl-archive", "ARCHIVE" to "pl-dup", "Best" to "pl-best"))

        PlaylistCache.forget(prefs, "archive", now)

        val cache = PlaylistCache.load(prefs, now)
        assertNull(PlaylistCache.find(cache, "Archive"))
        assertEquals("pl-best", PlaylistCache.find(cache, "Best"))
    }

    @Test
    fun `forgetting a name that is not cached is a no-op`() {
        store(mapOf("Best" to "pl-best"), writtenAt = now - 1_000L)

        PlaylistCache.forget(prefs, "Archive", now)

        assertEquals("pl-best", PlaylistCache.find(PlaylistCache.load(prefs, now), "Best"))
        // Nothing was rewritten, so the TTL did not restart either.
        assertEquals(now - 1_000L, prefs.getLong(AppConstants.KEY_PLAYLIST_CACHE_TIMESTAMP, 0L))
    }

    @Test
    fun `forgetting with nothing cached at all does not throw`() {
        PlaylistCache.forget(prefs, "Archive", now)

        assertTrue(prefs.values.isEmpty())
    }

    @Test
    fun `an entry older than the TTL is ignored`() {
        store(mapOf("Archive" to "pl-archive"), writtenAt = now - AppConstants.PLAYLIST_CACHE_TTL_MS - 1)

        assertNull(PlaylistCache.find(PlaylistCache.load(prefs, now), "Archive"))
    }

    @Test
    fun `an entry exactly at the TTL still counts`() {
        store(mapOf("Archive" to "pl-archive"), writtenAt = now - AppConstants.PLAYLIST_CACHE_TTL_MS)

        assertEquals("pl-archive", PlaylistCache.find(PlaylistCache.load(prefs, now), "Archive"))
    }

    @Test
    fun `an absent cache reads as empty`() {
        assertEquals(0, PlaylistCache.load(prefs, now).length())
    }

    @Test
    fun `a corrupt cache blob degrades to empty instead of throwing`() {
        prefs.edit()
            .putString(AppConstants.KEY_PLAYLIST_CACHE, "{\"Archive\":\"pl-")
            .putLong(AppConstants.KEY_PLAYLIST_CACHE_TIMESTAMP, now)
            .apply()

        assertEquals(0, PlaylistCache.load(prefs, now).length())
    }

    @Test
    fun `saving restarts the TTL`() {
        store(mapOf("Archive" to "pl-archive"), writtenAt = now - AppConstants.PLAYLIST_CACHE_TTL_MS - 1)
        val later = now + 5_000L

        PlaylistCache.save(prefs, JSONObject(mapOf("Best" to "pl-best")), later)

        assertEquals("pl-best", PlaylistCache.find(PlaylistCache.load(prefs, later), "Best"))
    }
}
