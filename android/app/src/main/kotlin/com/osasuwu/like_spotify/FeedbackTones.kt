package com.osasuwu.like_spotify

import kotlin.math.PI
import kotlin.math.sin

/** What a feedback tone confirms. Each kind has one tone and one vibration. */
enum class FeedbackKind { LIKE, ERROR, UNDO }

/**
 * The feedback tones as (frequency Hz, duration ms) segments, and their PCM
 * synthesis. Pure Kotlin, so JUnit covers it without an Android API.
 *
 * The segments and the synthesis are the desktop's (`_TONE_SEGMENTS` and
 * `_synth_tone` in `like_spotify/hosts/windows/feedback.py`), number for
 * number, so a like sounds the same on the phone and on the PC. A pytest
 * reads the tables below and fails when the two drift apart — keep the
 * `tone(<hz> to <ms>, ...)` form it parses.
 */
object FeedbackTones {
    const val SAMPLE_RATE = 44100

    /** Rising pair. */
    val LIKE = tone(784 to 90, 1175 to 110)

    /** Low double buzz. */
    val ERROR = tone(220 to 90, 220 to 90)

    /** The like pair, falling: the like taken back. */
    val UNDO = tone(1175 to 90, 784 to 110)

    private const val PEAK = 24000
    private const val FADE_MS = 5
    private const val GAP_MS = 30

    fun segments(kind: FeedbackKind): List<Pair<Int, Int>> = when (kind) {
        FeedbackKind.LIKE -> LIKE
        FeedbackKind.ERROR -> ERROR
        FeedbackKind.UNDO -> UNDO
    }

    /**
     * 16-bit mono PCM for [segments] at [volume] (0.0–1.0): each segment a sine
     * with a 5 ms fade in and out, followed by 30 ms of silence.
     */
    fun synth(segments: List<Pair<Int, Int>>, volume: Double): ShortArray {
        val peak = PEAK * volume.coerceIn(0.0, 1.0)
        val fade = SAMPLE_RATE * FADE_MS / 1000
        val gap = SAMPLE_RATE * GAP_MS / 1000
        val out = ShortArray(segments.sumOf { (_, ms) -> SAMPLE_RATE * ms / 1000 + gap })
        var at = 0
        for ((freq, ms) in segments) {
            val n = SAMPLE_RATE * ms / 1000
            for (i in 0 until n) {
                val amp = when {
                    i < fade -> i.toDouble() / fade
                    i > n - fade -> (n - i).toDouble() / fade
                    else -> 1.0
                }
                out[at + i] = (sin(2 * PI * freq * i / SAMPLE_RATE) * amp * peak).toInt().toShort()
            }
            at += n + gap
        }
        return out
    }

    /** Playback length of [segments] in milliseconds, gaps included. */
    fun durationMs(segments: List<Pair<Int, Int>>): Long =
        segments.sumOf { (_, ms) -> ms + GAP_MS }.toLong()

    private fun tone(vararg segments: Pair<Int, Int>): List<Pair<Int, Int>> = segments.toList()
}
