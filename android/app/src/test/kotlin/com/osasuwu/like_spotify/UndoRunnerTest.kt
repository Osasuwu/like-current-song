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

        override fun unsave(trackUri: String): ApiResult =
            call("unsave").also { if (it.success) library -= trackUri }

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
