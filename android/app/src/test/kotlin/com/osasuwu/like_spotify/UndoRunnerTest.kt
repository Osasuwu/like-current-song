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
}
