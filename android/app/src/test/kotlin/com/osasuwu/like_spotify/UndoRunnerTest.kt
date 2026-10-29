package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Reverting a journalled like (#267). The Spotify calls are a fake that keeps
 * the library and the playlists the way Spotify does -- a playlist DELETE
 * takes every copy of the track -- so each test can state the account before
 * the press and check the undo puts it back.
 */
class UndoRunnerTest {

    private val uri = "spotify:track:trk-a"
    private val other = "spotify:track:trk-b"

    private inner class Account(
        val library: MutableSet<String> = mutableSetOf(),
        val playlists: MutableMap<String, MutableList<String>> = mutableMapOf(),
    ) : UndoRunner.Ops {
        val calls = mutableListOf<String>()
        val failing = mutableSetOf<String>()

        private fun call(name: String): ApiResult {
            calls += name
            return if (name in failing) ApiResult(false, 500, "boom") else ApiResult(true, 200)
        }

        /** The phone's own stores (#273): the real [LocalCounters] over in-memory prefs. */
        val phone = FakeSharedPreferences()

        override fun forgetPromoted(trackId: String) {
            calls += "forget promoted"
            LocalCounters.forgetPromoted(phone, trackId)
        }

        /** The artists the user follows on Spotify. */
        val following = mutableSetOf<String>()

        /** The counter sheet's artist tab: this user's rows, as "artist track". */
        val sheetRows = mutableSetOf<String>()

        override fun forgetArtistTrack(artistId: String, trackId: String) {
            calls += "forget artist track"
            LocalCounters.forgetArtistTrack(phone, artistId, trackId)
        }

        override fun clearArtistTrackRow(sheet: LikeCounter.Target, artistId: String, trackId: String): String? {
            calls += "clear row $artistId"
            if ("clear row $artistId" in failing) return "the counter sheet refused to clear the row (HTTP 500)"
            sheetRows -= "$artistId $trackId"
            return null
        }

        override fun unfollow(artistId: String): ApiResult =
            call("unfollow $artistId").also { if (it.success) following -= artistId }

        override fun forgetFollowed(artistId: String) {
            calls += "forget followed"
            LocalCounters.forgetFollowed(phone, artistId)
        }

        override fun unsave(trackUri: String): ApiResult =
            call("unsave").also { if (it.success) library -= trackUri }

        /** The songs rated thumbs-up in the playing app's media session (#274). */
        val sessionRated = mutableSetOf<String>()

        override fun unrateInSession(song: String): String? {
            calls += "unrate $song"
            if ("unrate $song" in failing) return "the song is no longer playing in YouTube Music"
            sessionRated -= song
            return null
        }

        override fun countInPlaylist(playlistId: String, trackId: String): Int {
            calls += "count $playlistId"
            if ("count $playlistId" in failing) throw IllegalStateException("count failed")
            return playlists.getValue(playlistId).count { it == "spotify:track:$trackId" }
        }

        override fun removeAll(playlistId: String, trackUri: String): ApiResult =
            call("remove $playlistId").also { if (it.success) playlists.getValue(playlistId).removeAll { u -> u == trackUri } }

        override fun add(playlistId: String, trackUri: String): ApiResult =
            call("add $playlistId").also { if (it.success) playlists.getValue(playlistId) += trackUri }

        /** The cooldown's last-liked stamps on the phone, by track id. */
        val stamps = mutableMapOf<String, Long>()

        override fun restoreLikedAt(trackId: String, previous: Long?) {
            calls += "restore stamp"
            if (previous == null) stamps -= trackId else stamps[trackId] = previous
        }

        /**
         * The shared counter sheets, by spreadsheet id, then track id. As the
         * real decrement does, a row at 0 or missing is left as it is and
         * answered as counted 0.
         */
        val sheets = mutableMapOf<String, MutableMap<String, Int>>()

        override fun decrementSheetCount(target: LikeCounter.Target, trackId: String): LikeCounter.CountOutcome {
            calls += "sheet decrement ${target.spreadsheetId}"
            if ("sheet decrement ${target.spreadsheetId}" in failing) {
                return LikeCounter.CountOutcome.failed("the counter sheet refused the lowered count", 500)
            }
            val counts = sheets.getValue(target.spreadsheetId)
            val current = counts[trackId] ?: 0
            if (current <= 0) return LikeCounter.CountOutcome.counted(0)
            counts[trackId] = current - 1
            return LikeCounter.CountOutcome.counted(current - 1)
        }

        /** This device's fallback counter: the real [LocalCounters] over in-memory prefs. */
        val prefs = FakeSharedPreferences()

        override fun decrementLocalCount(trackId: String) {
            calls += "local decrement"
            LocalCounters.decrement(prefs, LocalCounters.Kind.TRACK, trackId)
        }

        fun localCount(trackId: String) = LocalCounters.count(prefs, LocalCounters.Kind.TRACK, trackId)

        fun snapshot() = library.toSet() to playlists.mapValues { it.value.sorted() }
    }

    private fun entry(vararg legs: UndoLeg) =
        UndoJournal.Entry("press-1", UndoJournal.State.UNDOING, "trk-a", uri, legs.toList())

    @Test
    fun `undoing a like of an unsaved track unsaves it, takes it out of the like playlist and puts it back in the archive`() {
        val account = Account(
            playlists = mutableMapOf("pl-like" to mutableListOf(other), "pl-arch" to mutableListOf(uri, other, uri)),
        )
        val before = account.snapshot()
        // What the like did:
        account.library += uri
        account.playlists.getValue("pl-like") += uri
        account.playlists.getValue("pl-arch").removeAll { it == uri }

        val result = UndoRunner.run(
            entry(
                UndoLeg.NativeSave(alreadySaved = false),
                UndoLeg.LikePlaylistAdd("pl-like"),
                UndoLeg.ArchiveRemove("pl-arch", copies = 2),
            ),
            account,
        )

        assertEquals(emptyList<UndoRunner.Failure>(), result.failures)
        assertEquals(before, account.snapshot())
    }

    @Test
    fun `a track that was saved before the press stays saved`() {
        val account = Account(library = mutableSetOf(uri), playlists = mutableMapOf("pl-like" to mutableListOf()))
        account.playlists.getValue("pl-like") += uri

        val result = UndoRunner.run(entry(UndoLeg.NativeSave(alreadySaved = true), UndoLeg.LikePlaylistAdd("pl-like")), account)

        assertEquals(emptyList<UndoRunner.Failure>(), result.failures)
        assertEquals(setOf(uri), account.library)
        assertEquals(emptyList<String>(), account.playlists.getValue("pl-like"))
        assertEquals(false, "unsave" in account.calls)
    }

    @Test
    fun `copies of the track that were in the like playlist before the press survive the undo`() {
        val account = Account(playlists = mutableMapOf("pl-like" to mutableListOf(uri, other, uri)))
        val before = account.snapshot()
        account.playlists.getValue("pl-like") += uri

        val result = UndoRunner.run(entry(UndoLeg.LikePlaylistAdd("pl-like")), account)

        assertEquals(emptyList<UndoRunner.Failure>(), result.failures)
        assertEquals(before, account.snapshot())
    }

    @Test
    fun `a like playlist the track already left is not written to`() {
        val account = Account(playlists = mutableMapOf("pl-like" to mutableListOf(other)))

        val result = UndoRunner.run(entry(UndoLeg.LikePlaylistAdd("pl-like")), account)

        assertEquals(emptyList<UndoRunner.Failure>(), result.failures)
        assertEquals(listOf("count pl-like"), account.calls)
    }

    @Test
    fun `legs are reverted newest first`() {
        val account = Account(playlists = mutableMapOf("pl-like" to mutableListOf(uri), "pl-arch" to mutableListOf()))
        account.library += uri

        UndoRunner.run(
            entry(
                UndoLeg.NativeSave(alreadySaved = false),
                UndoLeg.LikePlaylistAdd("pl-like"),
                UndoLeg.ArchiveRemove("pl-arch", copies = 1),
            ),
            account,
        )

        assertEquals(listOf("add pl-arch", "count pl-like", "remove pl-like", "unsave"), account.calls)
    }

    @Test
    fun `a failed leg is named and the remaining legs are still reverted`() {
        val account = Account(playlists = mutableMapOf("pl-like" to mutableListOf(uri), "pl-arch" to mutableListOf()))
        account.library += uri
        account.failing += "count pl-like"
        account.failing += "add pl-arch"

        val result = UndoRunner.run(
            entry(
                UndoLeg.NativeSave(alreadySaved = false),
                UndoLeg.LikePlaylistAdd("pl-like"),
                UndoLeg.ArchiveRemove("pl-arch", copies = 1),
            ),
            account,
        )

        assertEquals(listOf("archive playlist", "like playlist"), result.failures.map { it.leg })
        assertEquals(emptySet<String>(), account.library)
    }

    @Test
    fun `the undone like's cooldown stamp gives way to the one before it`() {
        // Otherwise the cooldown would skip the next like of the track the
        // user just undid.
        val account = Account()
        account.stamps["trk-a"] = 9_000L
        account.stamps["trk-b"] = 3_000L

        val result = UndoRunner.run(entry(UndoLeg.CooldownStamp(previous = 1_000L)), account)

        assertEquals(emptyList<UndoRunner.Failure>(), result.failures)
        assertEquals(mapOf("trk-a" to 1_000L, "trk-b" to 3_000L), account.stamps)
    }

    @Test
    fun `a rating made in the media session is taken back there, not through the library`() {
        val account = Account()
        account.sessionRated += "song-a"
        account.library += uri

        val result = UndoRunner.run(entry(UndoLeg.NativeSave(alreadySaved = false, sessionSong = "song-a")), account)

        assertEquals(emptyList<UndoRunner.Failure>(), result.failures)
        assertEquals(emptySet<String>(), account.sessionRated)
        assertEquals(listOf("unrate song-a"), account.calls)
    }

    @Test
    fun `a session rating that cannot be taken back is named as the native save`() {
        val account = Account()
        account.failing += "unrate song-a"

        val result = UndoRunner.run(entry(UndoLeg.NativeSave(alreadySaved = false, sessionSong = "song-a")), account)

        assertEquals(
            listOf(UndoRunner.Failure("native save", "the song is no longer playing in YouTube Music")),
            result.failures,
        )
    }

    @Test
    fun `a session rating the user made before the press is left alone`() {
        val account = Account()
        account.sessionRated += "song-a"

        UndoRunner.run(entry(UndoLeg.NativeSave(alreadySaved = true, sessionSong = "song-a")), account)

        assertEquals(setOf("song-a"), account.sessionRated)
        assertEquals(emptyList<String>(), account.calls)
    }

    @Test
    fun `a cooldown stamp recorded under its own key is restored under that key, not the track's`() {
        val account = Account()
        account.stamps["trk-a"] = 9_000L
        account.stamps["song-a"] = 8_000L

        UndoRunner.run(entry(UndoLeg.CooldownStamp(previous = 1_000L, key = "song-a")), account)

        assertEquals(mapOf("trk-a" to 9_000L, "song-a" to 1_000L), account.stamps)
    }

    // ---- best playlist and auto-follow (#273) -------------------------------------------------

    /** One run of the best-playlist rule for trk-a at [count] likes, against [account]'s "pl-best". */
    private fun promote(account: Account, count: Int) = BestPromotion.run(
        account.phone,
        count,
        3,
        "trk-a",
        isInPlaylist = { uri in account.playlists.getValue("pl-best") },
        add = { account.playlists.getValue("pl-best") += uri; true },
    )

    @Test
    fun `an undone promotion takes the track out of best, and the next qualifying like promotes it again`() {
        val account = Account(playlists = mutableMapOf("pl-best" to mutableListOf(other)))
        LocalCounters.markTrackPromoted(account.phone, "trk-b")
        val before = account.snapshot()
        // What the like did: its count reached the threshold.
        assertEquals(BestPromotion.Outcome.ADDED, promote(account, count = 3))

        val result = UndoRunner.run(entry(UndoLeg.BestPromote("pl-best")), account)

        assertEquals(emptyList<UndoRunner.Failure>(), result.failures)
        assertEquals(before, account.snapshot())
        assertEquals(setOf("trk-b"), LocalCounters.promotedTracks(account.phone))
        // The undone like's count went back with it, so the next like counts 3 again.
        assertEquals(BestPromotion.Outcome.ADDED, promote(account, count = 3))
        assertEquals(listOf(other, uri), account.playlists.getValue("pl-best"))
    }

    private val artistSheet = LikeCounter.Target("sheet-1", "me")

    /** The artist's distinct tracks as this device holds them. */
    private fun localTracks(account: Account) = LocalCounters.parseArtistTracks(
        account.phone.getString(AppConstants.KEY_ARTIST_LIKED_TRACKS, null),
    )

    /**
     * An account where trk-b by a1 was liked before, and a press of trk-a then
     * took a1 to the follow threshold: a new track on the phone and on the
     * sheet, and a follow.
     */
    private fun followedByThePress(): Account {
        val account = Account()
        account.following += "a2"
        LocalCounters.markArtistFollowed(account.phone, "a2")
        LocalCounters.recordArtistTrack(account.phone, "a1", "trk-b")
        account.sheetRows += "a1 trk-b"
        // What the like did:
        LocalCounters.recordArtistTrack(account.phone, "a1", "trk-a")
        account.sheetRows += "a1 trk-a"
        account.following += "a1"
        LocalCounters.markArtistFollowed(account.phone, "a1")
        return account
    }

    private val followLegs = arrayOf(
        UndoLeg.ArtistTrack("a1"),
        UndoLeg.ArtistTrackRow("a1", artistSheet),
        UndoLeg.ArtistFollow("a1", alreadyFollowed = false),
    )

    @Test
    fun `an undone auto-follow unfollows the artist and puts its tally back where it was`() {
        val account = followedByThePress()

        val result = UndoRunner.run(entry(*followLegs), account)

        assertEquals(emptyList<UndoRunner.Failure>(), result.failures)
        assertEquals(setOf("a2"), account.following)
        assertEquals(setOf("a2"), LocalCounters.followedArtists(account.phone))
        assertEquals(mapOf("a1" to setOf("trk-b")), localTracks(account))
        assertEquals(setOf("a1 trk-b"), account.sheetRows)
    }

    @Test
    fun `an artist the user followed before the press stays followed`() {
        val account = Account()
        account.following += "a1"
        LocalCounters.markArtistFollowed(account.phone, "a1")

        val result = UndoRunner.run(entry(UndoLeg.ArtistFollow("a1", alreadyFollowed = true)), account)

        assertEquals(emptyList<UndoRunner.Failure>(), result.failures)
        assertEquals(setOf("a1"), account.following)
        assertEquals(setOf("a1"), LocalCounters.followedArtists(account.phone))
        assertEquals(emptyList<String>(), account.calls)
    }

    @Test
    fun `a failed unfollow is named, keeps its followed mark, and the other legs still revert`() {
        val account = followedByThePress()
        account.playlists["pl-best"] = mutableListOf(uri)
        LocalCounters.markTrackPromoted(account.phone, "trk-a")
        account.failing += "unfollow a1"

        val result = UndoRunner.run(entry(UndoLeg.BestPromote("pl-best"), *followLegs), account)

        assertEquals(listOf("artist follow"), result.failures.map { it.leg })
        // Still followed on Spotify, so still remembered as followed.
        assertEquals(setOf("a1", "a2"), LocalCounters.followedArtists(account.phone))
        assertEquals(mapOf("a1" to setOf("trk-b")), localTracks(account))
        assertEquals(setOf("a1 trk-b"), account.sheetRows)
        assertEquals(emptyList<String>(), account.playlists.getValue("pl-best"))
        assertEquals(emptySet<String>(), LocalCounters.promotedTracks(account.phone))
    }

    @Test
    fun `a sheet row that would not clear is named with its reason`() {
        val account = followedByThePress()
        account.failing += "clear row a1"

        val result = UndoRunner.run(entry(*followLegs), account)

        assertEquals(
            listOf(UndoRunner.Failure("artist tally sheet row", "the counter sheet refused to clear the row (HTTP 500)")),
            result.failures,
        )
        assertEquals(setOf("a2"), account.following)
    }

    @Test
    fun `a failed write is reported with its status code`() {
        val account = Account(library = mutableSetOf(uri))
        account.failing += "unsave"

        val result = UndoRunner.run(entry(UndoLeg.NativeSave(alreadySaved = false)), account)

        assertEquals(listOf(UndoRunner.Failure("native save", "HTTP 500: boom")), result.failures)
    }

    // ---- track counter (#272) -------------------------------------------------

    private val sheet = LikeCounter.Target(spreadsheetId = "sheet-1", userId = "user-1")

    @Test
    fun `an undone like the sheet counted takes the sheet back to its count before the press, not this device`() {
        val account = Account()
        // Two likes this device counted while the sheet was unreachable, earlier.
        repeat(2) { LocalCounters.increment(account.prefs, LocalCounters.Kind.TRACK, "trk-a") }
        account.sheets["sheet-1"] = mutableMapOf("trk-a" to 4, "trk-b" to 9)
        // What the like did:
        account.sheets.getValue("sheet-1")["trk-a"] = 5

        val result = UndoRunner.run(entry(UndoLeg.TrackCount(sheet)), account)

        assertEquals(emptyList<UndoRunner.Failure>(), result.failures)
        assertEquals(mapOf("trk-a" to 4, "trk-b" to 9), account.sheets["sheet-1"])
        assertEquals(2, account.localCount("trk-a"))
    }

    @Test
    fun `an undone like this device counted takes this device back to its count before the press, not the sheet`() {
        val account = Account()
        account.sheets["sheet-1"] = mutableMapOf("trk-a" to 7)
        LocalCounters.increment(account.prefs, LocalCounters.Kind.TRACK, "trk-a")
        // What the like did, the sheet being unreachable:
        LocalCounters.increment(account.prefs, LocalCounters.Kind.TRACK, "trk-a")

        val result = UndoRunner.run(entry(UndoLeg.TrackCount(sheet = null)), account)

        assertEquals(emptyList<UndoRunner.Failure>(), result.failures)
        assertEquals(1, account.localCount("trk-a"))
        assertEquals(mapOf("trk-a" to 7), account.sheets["sheet-1"])
        assertEquals(false, account.calls.any { it.startsWith("sheet decrement") })
    }

    @Test
    fun `a counter that cannot be lowered is named, and the library, playlists and stamp are still reverted`() {
        val account = Account(playlists = mutableMapOf("pl-like" to mutableListOf(other), "pl-arch" to mutableListOf(uri)))
        account.sheets["sheet-1"] = mutableMapOf("trk-a" to 3)
        account.stamps["trk-a"] = 9_000L
        val before = account.snapshot()
        // What the like did, in the order the worker does it -- the counter last:
        account.library += uri
        account.playlists.getValue("pl-like") += uri
        account.playlists.getValue("pl-arch").removeAll { it == uri }
        account.failing += "sheet decrement sheet-1"

        val result = UndoRunner.run(
            entry(
                UndoLeg.NativeSave(alreadySaved = false),
                UndoLeg.LikePlaylistAdd("pl-like"),
                UndoLeg.CooldownStamp(previous = 1_000L),
                UndoLeg.ArchiveRemove("pl-arch", copies = 1),
                UndoLeg.TrackCount(sheet),
            ),
            account,
        )

        assertEquals(
            listOf(UndoRunner.Failure("track counter (sheet)", "the counter sheet refused the lowered count (HTTP 500)")),
            result.failures,
        )
        assertEquals(before, account.snapshot())
        assertEquals(1_000L, account.stamps["trk-a"])
    }

    @Test
    fun `the two counter legs are named apart, so the log says which counter failed`() {
        assertEquals("track counter (sheet)", UndoRunner.legName(UndoLeg.TrackCount(sheet)))
        assertEquals("track counter (this device)", UndoRunner.legName(UndoLeg.TrackCount(sheet = null)))
    }

    @Test
    fun `a library or playlist leg that fails still lets the counter go back`() {
        val account = Account(playlists = mutableMapOf("pl-like" to mutableListOf(uri)))
        account.library += uri
        account.sheets["sheet-1"] = mutableMapOf("trk-a" to 2)
        account.failing += "unsave"
        account.failing += "count pl-like"

        val result = UndoRunner.run(
            entry(
                UndoLeg.NativeSave(alreadySaved = false),
                UndoLeg.LikePlaylistAdd("pl-like"),
                UndoLeg.TrackCount(sheet),
            ),
            account,
        )

        assertEquals(listOf("like playlist", "native save"), result.failures.map { it.leg })
        assertEquals(mapOf("trk-a" to 1), account.sheets["sheet-1"])
    }
}
