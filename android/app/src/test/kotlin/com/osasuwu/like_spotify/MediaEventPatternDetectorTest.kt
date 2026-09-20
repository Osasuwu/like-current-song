package com.osasuwu.like_spotify

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Kotlin half of the trigger, which is what runs with the screen off.
 *
 * These cases deliberately mirror the Dart suite for the twin implementation
 * (`test/domain/services/signal_pattern_matcher_test.dart`), so the two halves
 * cannot drift apart unnoticed. The Dart twin reads the clock itself and its
 * time-dependent cases lean on real delays; this one is handed the timestamp,
 * so the same cases become exact.
 *
 * Timestamps are wall-clock milliseconds — the service feeds
 * `System.currentTimeMillis()` — and the fixture starts from a realistic epoch
 * value on purpose: the debounce compares against a zero-initialised
 * "last trigger", so small synthetic timestamps would make the very first
 * trigger look like a bounce.
 */
class MediaEventPatternDetectorTest {

    private val t0 = 1_700_000_000_000L

    private fun detector(
        pattern: List<String>,
        windowMs: Long = 5_000L,
        debounceMs: Long = 500L
    ) = MediaEventPatternDetector(
        windowMsProvider = { windowMs },
        debounceMsProvider = { debounceMs },
        patternProvider = { pattern }
    )

    // ---- basic pattern matching -------------------------------------------------

    @Test
    fun `matches a two-event pattern - pause then play`() {
        val detector = detector(listOf("pause", "play"))

        assertFalse(detector.onEvent("pause", t0))
        assertTrue(detector.onEvent("play", t0 + 10))
    }

    @Test
    fun `does not match the wrong order - play then pause`() {
        val detector = detector(listOf("pause", "play"))

        detector.onEvent("play", t0)

        assertFalse(detector.onEvent("pause", t0 + 10))
    }

    @Test
    fun `a partial pattern does not fire`() {
        val detector = detector(listOf("pause", "play"))

        assertFalse(detector.onEvent("pause", t0))
    }

    // ---- event validation -------------------------------------------------

    @Test
    fun `only play and pause are accepted`() {
        assertTrue(detector(listOf("play")).onEvent("play", t0))
        assertFalse(detector(listOf("play")).onEvent("pause", t0))
        assertFalse(detector(listOf("play")).onEvent("invalid", t0))
    }

    @Test
    fun `a pattern of events that can never arrive never fires`() {
        // The UI only ever offers play/pause, but a hand-edited pref could name
        // anything; such a pattern has to stay inert rather than misfire.
        val detector = detector(listOf("skip", "next"))

        assertFalse(detector.onEvent("skip", t0))
        assertFalse(detector.onEvent("next", t0 + 10))
    }

    @Test
    fun `an unknown event does not disturb a pattern in progress`() {
        // Unknown events are dropped before they reach the buffer, so they
        // neither advance nor reset a partial match.
        val detector = detector(listOf("pause", "play"))

        assertFalse(detector.onEvent("pause", t0))
        assertFalse(detector.onEvent("skip", t0 + 10))
        assertTrue(detector.onEvent("play", t0 + 20))
    }

    // ---- single-event patterns -------------------------------------------------

    @Test
    fun `a single-event pattern fires on that event`() {
        assertTrue(detector(listOf("pause")).onEvent("pause", t0))
        assertTrue(detector(listOf("play")).onEvent("play", t0))
    }

    @Test
    fun `a single-event pattern ignores the other event`() {
        assertFalse(detector(listOf("pause")).onEvent("play", t0))
    }

    // ---- three-event patterns -------------------------------------------------

    @Test
    fun `matches a three-event sequence`() {
        val detector = detector(listOf("pause", "play", "pause"))

        assertFalse(detector.onEvent("pause", t0))
        assertFalse(detector.onEvent("play", t0 + 10))
        assertTrue(detector.onEvent("pause", t0 + 20))
    }

    @Test
    fun `an incomplete three-event sequence does not fire`() {
        val detector = detector(listOf("pause", "play", "pause"))

        assertFalse(detector.onEvent("pause", t0))
        assertFalse(detector.onEvent("play", t0 + 10))
    }

    // ---- matching on the tail -------------------------------------------------

    @Test
    fun `the pattern is matched against the tail, not the whole buffer`() {
        val detector = detector(listOf("pause", "play"))

        detector.onEvent("play", t0)

        assertFalse(detector.onEvent("pause", t0 + 10))
        assertTrue(detector.onEvent("play", t0 + 20))
    }

    @Test
    fun `leading noise before the pattern is tolerated`() {
        val detector = detector(listOf("pause", "play"))

        detector.onEvent("play", t0)
        detector.onEvent("play", t0 + 10)

        assertFalse(detector.onEvent("pause", t0 + 20))
        assertTrue(detector.onEvent("play", t0 + 30))
    }

    // ---- the time window -------------------------------------------------

    @Test
    fun `an event that fell out of the window no longer counts`() {
        val detector = detector(listOf("pause", "play"), windowMs = 50L)

        detector.onEvent("pause", t0)

        assertFalse(detector.onEvent("play", t0 + 60))
    }

    @Test
    fun `an event exactly at the edge of the window still counts`() {
        // The window is inclusive: only events *older* than it are dropped.
        val detector = detector(listOf("pause", "play"), windowMs = 50L)

        detector.onEvent("pause", t0)

        assertTrue(detector.onEvent("play", t0 + 50))
    }

    // ---- the debounce -------------------------------------------------

    @Test
    fun `a second match inside the debounce window is swallowed`() {
        val detector = detector(listOf("pause"), debounceMs = 100L)

        assertTrue(detector.onEvent("pause", t0))
        assertFalse(detector.onEvent("pause", t0 + 50))
    }

    @Test
    fun `a match is allowed again once the debounce has passed`() {
        val detector = detector(listOf("pause"), debounceMs = 100L)

        assertTrue(detector.onEvent("pause", t0))
        assertFalse(detector.onEvent("pause", t0 + 50))
        assertTrue(detector.onEvent("pause", t0 + 150))
    }

    @Test
    fun `a zero debounce lets back-to-back patterns through`() {
        val detector = detector(listOf("pause", "play"), debounceMs = 0L)

        detector.onEvent("pause", t0)
        assertTrue(detector.onEvent("play", t0 + 10))

        detector.onEvent("pause", t0 + 20)
        assertTrue(detector.onEvent("play", t0 + 30))
    }

    // ---- state after a match -------------------------------------------------

    @Test
    fun `the buffer is cleared after a match`() {
        // The event that completed the pattern must not also count towards the
        // next one: with a repeated pattern, one more event after a match would
        // otherwise fire again. The third event is far enough out that the
        // debounce is not what is blocking it.
        val detector = detector(listOf("play", "play"))

        detector.onEvent("play", t0)
        assertTrue(detector.onEvent("play", t0 + 10))

        assertFalse(detector.onEvent("play", t0 + 600))
    }

    @Test
    fun `a partial match survives events that do not complete it`() {
        val detector = detector(listOf("pause", "play", "pause"))

        detector.onEvent("pause", t0)
        detector.onEvent("play", t0 + 10)

        assertTrue(detector.onEvent("pause", t0 + 20))
    }

    // ---- degenerate config -------------------------------------------------

    @Test
    fun `an empty pattern never fires`() {
        // A pattern that parsed to nothing (blank pref) is inert here. The Dart
        // twin treats the same input as a zero-length pattern that matches every
        // event; this half is the one that runs unattended in the background, so
        // it refuses rather than firing on every media button.
        val detector = detector(emptyList())

        assertFalse(detector.onEvent("play", t0))
        assertFalse(detector.onEvent("pause", t0 + 10))
    }
}
