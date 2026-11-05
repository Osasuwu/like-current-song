package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.w3c.dom.Element

/**
 * The app owns no MediaSession and registers for no media button (#300).
 *
 * Android gives the media button to the most recently started playback whose
 * owner has a MediaSession. The feedback tone is such a playback, so while
 * this app held a session of its own it became the media-button session for
 * about half a second after every like, undo or error tone: a headset press
 * in that window went to the app's empty session and reached nobody, and over
 * Bluetooth the headset was re-addressed to that session and back on every
 * tone. A UID with no session is skipped, tone or no tone.
 *
 * A lint over the whole module, not a pin on one file: the next session added
 * anywhere (a media3 `MediaSession.Builder`, a compat session for a widget)
 * brings the same hijack back. Reads the real sources and the real manifest
 * from the module directory Gradle runs unit tests in.
 */
class NoOwnMediaSessionTest {

    private val moduleDir: File = run {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null && !File(dir, "src/main/AndroidManifest.xml").isFile) dir = dir.parentFile
        checkNotNull(dir) { "no src/main/AndroidManifest.xml above ${System.getProperty("user.dir")}" }
    }

    /** What a session of our own looks like in source, each with the name the failure gives it. */
    private val sessionConstructs = listOf(
        Regex("""\bMediaSessionCompat\s*\(""") to "MediaSessionCompat(...)",
        Regex("""\bMediaSession\s*\(""") to "MediaSession(...)",
        Regex("""\bMedia(Library)?Session\.Builder\b""") to "media3 MediaSession.Builder",
        Regex("""^\s*import\s+android\.support\.v4\.media\.session\.MediaSessionCompat\b""") to
            "import of MediaSessionCompat",
    )

    @Test
    fun `no source under main constructs a MediaSession`() {
        val sources = File(moduleDir, "src/main").walkTopDown()
            .filter { it.isFile && (it.extension == "kt" || it.extension == "java") }
            .toList()
        assertTrue(
            "the walk must reach the service; saw ${sources.map { it.name }}",
            sources.any { it.name == "MediaButtonForegroundService.kt" },
        )

        val violations = sources.flatMap { file ->
            codeLines(file.readText()).withIndex().flatMap { (index, line) ->
                sessionConstructs.filter { (regex, _) -> regex.containsMatchIn(line) }
                    .map { (_, what) -> "${file.relativeTo(moduleDir).path}:${index + 1} $what" }
            }
        }
        assertEquals(
            "the app must own no MediaSession (#300); found:\n" + violations.joinToString("\n"),
            emptyList<String>(),
            violations,
        )
    }

    @Test
    fun `the manifest registers no receiver for the media button`() {
        val manifest = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
            .newDocumentBuilder()
            .parse(File(moduleDir, "src/main/AndroidManifest.xml"))
        val receivers = manifest.getElementsByTagName("receiver").let { nodes ->
            (0 until nodes.length).map { nodes.item(it) as Element }
        }
        assertTrue("the walk must reach a receiver; saw none", receivers.isNotEmpty())

        val mediaButtonReceivers = receivers.filter { receiver ->
            receiver.getElementsByTagName("action").let { actions ->
                (0 until actions.length).any { i ->
                    (actions.item(i) as Element).getAttributeNS(ANDROID_NS, "name") ==
                        "android.intent.action.MEDIA_BUTTON"
                }
            }
        }.map { it.getAttributeNS(ANDROID_NS, "name") }
        assertEquals(
            "no receiver may take the media button (#300); found: $mediaButtonReceivers",
            emptyList<String>(),
            mediaButtonReceivers,
        )
    }

    /**
     * [text] with comments blanked, one entry per source line so indices are
     * line numbers. A `/* */` spanning lines keeps its newlines; a `//` tail
     * goes, including one inside a string literal — that only ever hides
     * text, never invents a match.
     */
    private fun codeLines(text: String): List<String> =
        text.replace(BLOCK_COMMENT) { match -> match.value.replace(Regex("[^\n]"), " ") }
            .lines()
            .map { it.substringBefore("//") }

    private companion object {
        const val ANDROID_NS = "http://schemas.android.com/apk/res/android"
        val BLOCK_COMMENT = Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL)
    }
}
