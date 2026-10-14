package com.osasuwu.like_spotify

import android.media.AudioAttributes
import com.osasuwu.like_spotify.ExternalPlaybackVeto.ActivePlayer
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Whether another app's player started around a matched pause (#248).
 *
 * An app that takes audio focus pauses the music, and when it lets go the
 * music resumes — the same `pause, play` the user's gesture makes. What tells
 * them apart is that a player nobody had a moment ago became active. The
 * music app's own resume is not that: its player leaves the active list at the
 * pause and rejoins it under the same identity.
 *
 * Timestamps follow the detector's: wall-clock milliseconds, the match at
 * [now]. The lookback is the default, 2000 ms (the 1500 ms window cap plus
 * 500 ms for a player that started just before the pause).
 */
class ExternalPlaybackVetoTest {

    private val now = 1_700_000_000_000L
    private val music = ActivePlayer(id = "music", usage = AudioAttributes.USAGE_MEDIA)
    private val other = ActivePlayer(id = "other", usage = AudioAttributes.USAGE_MEDIA)

    private fun veto(vararg changes: Pair<Long, List<ActivePlayer>>) =
        ExternalPlaybackVeto().apply {
            changes.forEach { (at, players) -> onPlayersChanged(at, players) }
        }

    @Test
    fun `the music app's own pause and resume is not vetoed`() {
        val veto = veto(
            now - 30_000 to listOf(music),
            now - 800 to emptyList(),
            now to listOf(music),
        )

        assertEquals(emptyList<ActivePlayer>(), veto.startedPlayers(now))
    }

    @Test
    fun `a player that starts after the pause vetoes it`() {
        val veto = veto(
            now - 30_000 to listOf(music),
            now - 1_000 to emptyList(),
            now - 950 to listOf(other),
            now - 100 to emptyList(),
            now to listOf(music),
        )

        assertEquals(listOf(other), veto.startedPlayers(now))
    }

    @Test
    fun `a player that starts just before the pause vetoes it`() {
        // Focus is requested before the pause lands, so the other player can
        // be first — here before the 1500 ms window even opens. It is new
        // against what was playing 2000 ms ago.
        val veto = veto(
            now - 30_000 to listOf(music),
            now - 1_700 to listOf(music, other),
            now - 1_500 to listOf(other),
            now - 100 to emptyList(),
            now to listOf(music),
        )

        assertEquals(listOf(other), veto.startedPlayers(now))
    }

    @Test
    fun `a player active since before the lookback does not veto`() {
        // Another app playing all along (a game, a second player) is not an
        // interruption. Its snapshot is older than the 10 s retention, so this
        // also needs the oldest entry kept as the baseline when history is
        // pruned.
        val veto = veto(
            now - 60_000 to listOf(music, other),
            now - 800 to listOf(other),
            now to listOf(music, other),
        )

        assertEquals(emptyList<ActivePlayer>(), veto.startedPlayers(now))
    }

    @Test
    fun `a player that came and went before the lookback does not veto`() {
        val veto = veto(
            now - 30_000 to listOf(music),
            now - 4_000 to listOf(music, other),
            now - 3_500 to listOf(music),
            now - 800 to emptyList(),
            now to listOf(music),
        )

        assertEquals(emptyList<ActivePlayer>(), veto.startedPlayers(now))
    }

    @Test
    fun `touch and accessibility sounds do not veto`() {
        // A tap on the notification shade's pause button clicks, and TalkBack
        // speaks it: both are the user's own gesture, not an interruption.
        val click = ActivePlayer(id = "click", usage = AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
        val talkBack = ActivePlayer(id = "talkback", usage = AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
        val veto = veto(
            now - 30_000 to listOf(music),
            now - 820 to listOf(music, click, talkBack),
            now - 800 to listOf(click, talkBack),
            now - 600 to emptyList(),
            now to listOf(music),
        )

        assertEquals(emptyList<ActivePlayer>(), veto.startedPlayers(now))
    }
}
