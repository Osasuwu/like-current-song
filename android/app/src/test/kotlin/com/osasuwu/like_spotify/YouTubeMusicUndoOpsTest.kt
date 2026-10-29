package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A YouTube Music like journalled the way the background liker journals it,
 * then undone through [UndoRunner] with [YouTubeMusicUndoOps] (#274): the
 * account and this device must read what they read before the press.
 */
class YouTubeMusicUndoOpsTest {

    /**
     * The parts of a YouTube account a like touches: video ratings,
     * playlists (YouTube keeps one item per copy) and channel subscriptions.
     */
    private class FakeAccount(
        val ratings: MutableMap<String, String> = mutableMapOf(),
        val playlists: Map<String, MutableList<String>> = mapOf(
            "PLlike" to mutableListOf(),
            "PLarchive" to mutableListOf(),
            "PLbest" to mutableListOf(),
        ),
        val subscriptions: MutableSet<String> = mutableSetOf(),
        /** Playlists whose items cannot be deleted: the API answers 500. */
        val refuseDeletesIn: Set<String> = emptySet(),
    ) {
        private val titles = mapOf("PLlike" to "Likes", "PLarchive" to "Archive", "PLbest" to "Best")

        /** itemId -> playlist; item ids are `<playlist>-<n>`, so a delete knows its playlist. */
        private var nextItem = 0
        private val items = mutableMapOf<String, Pair<String, String>>()

        init {
            playlists.forEach { (id, videos) -> videos.forEach { items["$id-${nextItem++}"] = id to it } }
        }

        fun copies(playlistId: String, videoId: String): Int =
            items.values.count { it == playlistId to videoId }

        fun call(method: String, url: String, body: String?): String {
            val path = url.removePrefix(YouTubeDataApi.API_BASE).substringBefore('?')
            fun param(name: String) = url.substringAfter("$name=", "").substringBefore('&')
            return when ("$method $path") {
                "GET /playlists" -> titles.entries.joinToString(",", """{"items":[""", "]}") { (id, title) ->
                    """{"id":"$id","snippet":{"title":"$title"}}"""
                }
                "GET /playlistItems" -> {
                    val playlistId = param("playlistId")
                    val videoId = param("videoId")
                    items.filterValues { it == playlistId to videoId }.keys
                        .joinToString(",", """{"items":[""", "]}") {
                            """{"id":"$it","contentDetails":{"videoId":"$videoId"}}"""
                        }
                }
                "POST /playlistItems" -> {
                    val playlistId = Regex("\"playlistId\":\"([^\"]+)\"").find(body!!)!!.groupValues[1]
                    val videoId = Regex("\"videoId\":\"([^\"]+)\"").find(body)!!.groupValues[1]
                    items["$playlistId-${nextItem++}"] = playlistId to videoId
                    "{}"
                }
                "DELETE /playlistItems" -> {
                    val itemId = param("id")
                    val playlistId = items[itemId]?.first ?: throw ApiFailure("playlistItemNotFound", 404)
                    if (playlistId in refuseDeletesIn) throw ApiFailure("YouTube Data API unavailable", 500)
                    items.remove(itemId)
                    ""
                }
                "POST /videos/rate" -> {
                    ratings[param("id")] = param("rating")
                    ""
                }
                "POST /subscriptions" -> {
                    val channelId = Regex("\"channelId\":\"([^\"]+)\"").find(body!!)!!.groupValues[1]
                    if (!subscriptions.add(channelId)) {
                        throw ApiFailure("already subscribed", 400, "subscriptionDuplicate")
                    }
                    """{"id":"sub-$channelId"}"""
                }
                "GET /subscriptions" -> {
                    val channelId = param("forChannelId")
                    if (channelId in subscriptions) """{"items":[{"id":"sub-$channelId"}]}""" else """{"items":[]}"""
                }
                "DELETE /subscriptions" -> {
                    subscriptions.remove(param("id").removePrefix("sub-"))
                    ""
                }
                else -> error("unexpected call: $method $url")
            }
        }
    }

    private val song = YouTubeMusicLiker.cooldownKey("Song", "Artist")

    /** Archive removal, best at one like and follow at one video: every extra on. */
    private fun everyRuleOn() = FakeSharedPreferences().apply {
        values[AppConstants.KEY_RULE_ARCHIVE_REMOVE_ENABLED] = true
        values[AppConstants.KEY_RULE_ARCHIVE_PLAYLIST_NAME] = "Archive"
        values[AppConstants.KEY_RULE_BEST_ENABLED] = true
        values[AppConstants.KEY_RULE_BEST_PLAYLIST_NAME] = "Best"
        values[AppConstants.KEY_RULE_BEST_THRESHOLD] = 1
        values[AppConstants.KEY_RULE_FOLLOW_ARTIST_ENABLED] = true
        values[AppConstants.KEY_RULE_FOLLOW_ARTIST_THRESHOLD] = 1
    }

    /**
     * One press, journalled as the background liker does: the Data API
     * rating (or none, when the video was rated already), the like
     * playlist's add, the cooldown stamp, then the extra actions. Returns
     * the journal entry.
     */
    private fun press(prefs: FakeSharedPreferences, account: FakeAccount): UndoJournal.Entry {
        val id = UndoJournal.beginLike(prefs, now = 1_000L, provider = MusicProvider.YTMUSIC)
        UndoJournal.setTrack(prefs, id, "vid", "vid")
        val journal: (UndoLeg) -> Unit = { UndoJournal.recordLeg(prefs, id, it) }
        val actions = YouTubeMusicExtraActions(prefs, account::call, { _, _, _, _ -> }, journal = journal)

        val alreadyRated = account.ratings["vid"] == "like"
        account.call("POST", "${YouTubeDataApi.API_BASE}/videos/rate?id=vid&rating=like", null)
        journal(UndoLeg.NativeSave(alreadySaved = alreadyRated))
        journal(UndoLeg.LikePlaylistAdd(actions.addToPlaylist("Likes", "vid", "like_playlist_add", null)!!))
        journal(UndoLeg.CooldownStamp(LocalCounters.lastLikedAt(prefs, song), key = song))
        LocalCounters.recordLikedAt(prefs, song, 1_000L)
        actions.run(YouTubeDataApi.Match("vid", "UCartist"), sharedLikeCount = null)
        return UndoJournal.entry(prefs, id)!!
    }

    private fun undo(prefs: FakeSharedPreferences, account: FakeAccount, entry: UndoJournal.Entry) =
        UndoRunner.run(entry, YouTubeMusicUndoOps(prefs, account::call))

    private fun trackCount(prefs: FakeSharedPreferences) =
        LocalCounters.count(prefs, LocalCounters.Kind.TRACK, YouTubeMusicExtraActions.countKey("vid"))

    private fun artistTracks(prefs: FakeSharedPreferences) =
        LocalCounters.parseArtistTracks(prefs.getString(AppConstants.KEY_ARTIST_LIKED_TRACKS, null))[
            YouTubeMusicExtraActions.countKey("UCartist"),
        ].orEmpty()

    @Test
    fun `undoing a like of an unrated song puts the account and this device back as they were`() {
        val prefs = everyRuleOn()
        val account = FakeAccount(playlists = mapOf(
            "PLlike" to mutableListOf(),
            "PLarchive" to mutableListOf("vid", "vid"),
            "PLbest" to mutableListOf(),
        ))
        val entry = press(prefs, account)
        // The press did everything it could.
        assertEquals("like", account.ratings["vid"])
        assertEquals(listOf(1, 0, 1), listOf("PLlike", "PLarchive", "PLbest").map { account.copies(it, "vid") })
        assertEquals(setOf("UCartist"), account.subscriptions)

        val result = undo(prefs, account, entry)

        assertEquals(emptyList<UndoRunner.Failure>(), result.failures)
        assertEquals("none", account.ratings["vid"])
        assertEquals(listOf(0, 2, 0), listOf("PLlike", "PLarchive", "PLbest").map { account.copies(it, "vid") })
        assertEquals(emptySet<String>(), account.subscriptions)
        assertEquals(0, trackCount(prefs))
        assertEquals(emptySet<String>(), LocalCounters.promotedTracks(prefs))
        assertEquals(emptySet<String>(), LocalCounters.followedArtists(prefs))
        assertEquals(emptySet<String>(), artistTracks(prefs))
        assertEquals(null, LocalCounters.lastLikedAt(prefs, song))
    }

    @Test
    fun `undoing a like of a song rated like before keeps the rating and reverts the rest`() {
        val prefs = everyRuleOn()
        // Rated like and in the like playlist already, from an earlier like.
        val account = FakeAccount(
            ratings = mutableMapOf("vid" to "like"),
            playlists = mapOf(
                "PLlike" to mutableListOf("vid"),
                "PLarchive" to mutableListOf("vid"),
                "PLbest" to mutableListOf(),
            ),
        )
        val entry = press(prefs, account)

        val result = undo(prefs, account, entry)

        assertEquals(emptyList<UndoRunner.Failure>(), result.failures)
        assertEquals("like", account.ratings["vid"])
        assertEquals(listOf(1, 1, 0), listOf("PLlike", "PLarchive", "PLbest").map { account.copies(it, "vid") })
        assertEquals(0, trackCount(prefs))
    }

    @Test
    fun `an undo leaves the best copy and the subscription the press did not make`() {
        val prefs = everyRuleOn()
        val account = FakeAccount(
            playlists = mapOf(
                "PLlike" to mutableListOf(),
                "PLarchive" to mutableListOf(),
                "PLbest" to mutableListOf("vid"),
            ),
            subscriptions = mutableSetOf("UCartist"),
        )
        val entry = press(prefs, account)

        val result = undo(prefs, account, entry)

        assertEquals(emptyList<UndoRunner.Failure>(), result.failures)
        assertEquals(1, account.copies("PLbest", "vid"))
        assertEquals(setOf("UCartist"), account.subscriptions)
        // The marks still agree with the account: in best, subscribed.
        assertEquals(setOf(YouTubeMusicExtraActions.countKey("vid")), LocalCounters.promotedTracks(prefs))
        assertEquals(setOf(YouTubeMusicExtraActions.countKey("UCartist")), LocalCounters.followedArtists(prefs))
    }

    @Test
    fun `an unfollow of a channel the user has since left counts as done`() {
        val prefs = everyRuleOn()
        val account = FakeAccount()
        val entry = press(prefs, account)
        account.subscriptions.clear()

        val result = undo(prefs, account, entry)

        assertEquals(emptyList<UndoRunner.Failure>(), result.failures)
        assertEquals(emptySet<String>(), LocalCounters.followedArtists(prefs))
    }

    @Test
    fun `a leg the API refuses is named with its reason and the other legs still revert`() {
        val prefs = everyRuleOn()
        val account = FakeAccount(
            playlists = mapOf(
                "PLlike" to mutableListOf(),
                "PLarchive" to mutableListOf("vid"),
                "PLbest" to mutableListOf(),
            ),
            refuseDeletesIn = setOf("PLbest"),
        )
        val entry = press(prefs, account)

        val result = undo(prefs, account, entry)

        assertEquals(listOf("best playlist"), result.failures.map { it.leg })
        assertTrue(result.failures.single().reason, result.failures.single().reason.contains("YouTube Data API unavailable"))
        assertEquals("none", account.ratings["vid"])
        assertEquals(listOf(0, 1), listOf("PLlike", "PLarchive").map { account.copies(it, "vid") })
        assertEquals(emptySet<String>(), account.subscriptions)
        // Still in best, so still marked promoted.
        assertEquals(setOf(YouTubeMusicExtraActions.countKey("vid")), LocalCounters.promotedTracks(prefs))
    }
}
