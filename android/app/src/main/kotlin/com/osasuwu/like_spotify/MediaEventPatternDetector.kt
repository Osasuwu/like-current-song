package com.osasuwu.like_spotify

/**
 * The media-button pattern matcher that actually runs. It lives here, in the
 * foreground service's process, because the Dart isolate is not alive when the
 * screen is off.
 *
 * Its twin is `lib/domain/services/signal_pattern_matcher.dart`, the Dart-side
 * executable spec of the same rules — that one is never called at trigger time.
 * The two must stay in step, as must their test files
 * (`MediaEventPatternDetectorTest.kt` and
 * `test/domain/services/signal_pattern_matcher_test.dart`), which mirror each
 * other on purpose.
 */
class MediaEventPatternDetector(
    private val windowMsProvider: () -> Long,
    private val debounceMsProvider: () -> Long,
    private val patternProvider: () -> List<String>
) {
    private val events = ArrayDeque<Pair<String, Long>>()
    private var lastTriggerAt = 0L

    fun onEvent(event: String, atMs: Long): Boolean {
        if (event != "play" && event != "pause") {
            return false
        }
        val pattern = patternProvider()
        if (pattern.isEmpty()) {
            return false
        }

        events.addLast(event to atMs)
        while (events.isNotEmpty() && atMs - events.first().second > windowMsProvider()) {
            events.removeFirst()
        }

        val debounce = debounceMsProvider()
        if (atMs - lastTriggerAt < debounce) {
            return false
        }

        if (matches(pattern)) {
            lastTriggerAt = atMs
            events.clear()
            return true
        }
        return false
    }

    private fun matches(pattern: List<String>): Boolean {
        if (events.size < pattern.size) {
            return false
        }
        val recent = events.takeLast(pattern.size).map { it.first }
        return recent == pattern
    }
}
