package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The phone's feedback synthesis against the desktop's (#266). The golden
 * samples below were rendered by `_synth_tone` in
 * `like_spotify/hosts/windows/feedback.py`; tests/test_feedback.py keeps the
 * segment tables themselves in step. Together they mean a like sounds the
 * same on both platforms.
 */
class FeedbackTonesTest {

    private fun pcm(kind: FeedbackKind, volume: Double = 1.0) =
        FeedbackTones.synth(FeedbackTones.segments(kind), volume)

    private fun assertSamples(expected: Map<Int, Int>, actual: ShortArray) {
        assertEquals(expected, expected.keys.associateWith { actual[it].toInt() })
    }

    @Test
    fun `like renders the desktop's like tone sample for sample`() {
        val like = pcm(FeedbackKind.LIKE)
        // 90 ms + 30 ms gap + 110 ms + 30 ms gap at 44.1 kHz.
        assertEquals(11466, like.size)
        assertSamples(
            mapOf(
                0 to 0, 1 to 12, 110 to -3307, 219 to -14839, 220 to -12718,
                1000 to -23635, 3968 to -28, 3969 to 0, 5291 to 0, 5292 to 0,
                5400 to -8196, 8000 to 19585, 11465 to 0,
            ),
            like,
        )
    }

    @Test
    fun `undo renders the desktop's undo tone sample for sample`() {
        val undo = pcm(FeedbackKind.UNDO)
        assertEquals(11466, undo.size)
        assertSamples(
            mapOf(
                0 to 0, 1 to 18, 110 to -5052, 219 to -20561, 220 to -18330,
                1000 to -18870, 3968 to -107, 3969 to 0, 5291 to 0, 5292 to 0,
                5400 to -5675, 8000 to 18704, 11465 to 0,
            ),
            undo,
        )
    }

    @Test
    fun `volume scales the waveform the way the desktop does`() {
        assertSamples(mapOf(1000 to -5908, 8000 to 4896), pcm(FeedbackKind.LIKE, volume = 0.25))
    }

    @Test
    fun `volume outside 0 to 1 is clamped`() {
        assertEquals(pcm(FeedbackKind.LIKE, 1.0).toList(), pcm(FeedbackKind.LIKE, 3.0).toList())
        assertEquals(0, pcm(FeedbackKind.LIKE, -1.0).maxOf { kotlin.math.abs(it.toInt()) })
    }

    @Test
    fun `playback is held open for every segment and gap`() {
        // The release delay is built on this; a short value cuts the tone off.
        assertEquals(260L, FeedbackTones.durationMs(FeedbackTones.LIKE))
        assertEquals(240L, FeedbackTones.durationMs(FeedbackTones.ERROR))
    }
}
