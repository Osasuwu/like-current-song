package com.osasuwu.like_spotify

import android.media.AudioDeviceInfo
import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The triple-tap mode's key decision (#158): which media key the listener
 * keeps, which it hands back to the player, and when it may keep PREVIOUS
 * at all. The listener answers from these alone, before anything in the like
 * pipeline runs, so a wrong answer here is a skip-back alongside a like or a
 * like nobody asked for.
 */
class MediaKeyCaptureTest {

    private val spotify = "com.spotify.music"
    private val podcasts = "au.com.shiftyjelly.pocketcasts"
    private val listensToSpotify: (String) -> Boolean = { it == spotify }

    // ---- when PREVIOUS may be kept ------------------------------------------

    @Test
    fun `with a Bluetooth output, notification access and the music app playing, PREVIOUS may like`() {
        assertTrue(TripleTapGate.mayCapture(true, listOf(spotify), listensToSpotify))
    }

    @Test
    fun `with nothing playing, PREVIOUS may like`() {
        assertTrue(TripleTapGate.mayCapture(true, emptyList(), listensToSpotify))
    }

    @Test
    fun `with no Bluetooth output connected, PREVIOUS passes through`() {
        assertFalse(TripleTapGate.mayCapture(false, listOf(spotify), listensToSpotify))
    }

    @Test
    fun `without notification access, PREVIOUS passes through`() {
        assertFalse(TripleTapGate.mayCapture(true, null, listensToSpotify))
    }

    @Test
    fun `while an app the like does not listen to is playing, PREVIOUS passes through`() {
        assertFalse(TripleTapGate.mayCapture(true, listOf(podcasts), listensToSpotify))
        assertFalse(TripleTapGate.mayCapture(true, listOf(spotify, podcasts), listensToSpotify))
    }

    // ---- the answer per key -------------------------------------------------

    private var gateReads = 0

    private fun capture(allowed: Boolean) = MediaKeyCapture {
        gateReads++
        allowed
    }.apply { listening = true }

    private fun MediaKeyCapture.down(code: Int, repeat: Int = 0) =
        onKey(code, KeyEvent.ACTION_DOWN, repeat)

    private fun MediaKeyCapture.up(code: Int) = onKey(code, KeyEvent.ACTION_UP, 0)

    @Test
    fun `a PREVIOUS press the gate allows is one press, and its UP is kept too`() {
        val capture = capture(allowed = true)

        assertEquals(MediaKeyCapture.Answer.PRESS, capture.down(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
        assertEquals(MediaKeyCapture.Answer.CONSUME, capture.up(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
    }

    @Test
    fun `a PREVIOUS press the gate refuses passes through, and so does its UP`() {
        val capture = capture(allowed = false)

        assertEquals(MediaKeyCapture.Answer.PASS, capture.down(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
        assertEquals(MediaKeyCapture.Answer.PASS, capture.up(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
    }

    @Test
    fun `every other media key passes through without reading the gate`() {
        val capture = capture(allowed = true)
        val others = listOf(
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PLAY,
            KeyEvent.KEYCODE_MEDIA_PAUSE,
            KeyEvent.KEYCODE_MEDIA_NEXT,
            KeyEvent.KEYCODE_HEADSETHOOK,
            KeyEvent.KEYCODE_MEDIA_STOP,
        )

        for (code in others) {
            assertEquals("DOWN $code", MediaKeyCapture.Answer.PASS, capture.down(code))
            assertEquals("UP $code", MediaKeyCapture.Answer.PASS, capture.up(code))
        }
        assertEquals(0, gateReads)
    }

    // ---- DOWN / UP pairing --------------------------------------------------

    @Test
    fun `the repeats of a kept PREVIOUS are kept and ask the gate nothing`() {
        val capture = capture(allowed = true)
        assertEquals(MediaKeyCapture.Answer.PRESS, capture.down(KeyEvent.KEYCODE_MEDIA_PREVIOUS))

        assertEquals(MediaKeyCapture.Answer.CONSUME, capture.down(KeyEvent.KEYCODE_MEDIA_PREVIOUS, repeat = 1))
        assertEquals(MediaKeyCapture.Answer.CONSUME, capture.down(KeyEvent.KEYCODE_MEDIA_PREVIOUS, repeat = 2))
        assertEquals(MediaKeyCapture.Answer.CONSUME, capture.up(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
        assertEquals(1, gateReads)
    }

    @Test
    fun `the repeats of a PREVIOUS that passed pass too`() {
        val capture = capture(allowed = false)
        capture.down(KeyEvent.KEYCODE_MEDIA_PREVIOUS)

        assertEquals(MediaKeyCapture.Answer.PASS, capture.down(KeyEvent.KEYCODE_MEDIA_PREVIOUS, repeat = 1))
        assertEquals(1, gateReads)
    }

    @Test
    fun `an UP with no DOWN before it passes, so a press begun before the listener is the player's`() {
        assertEquals(MediaKeyCapture.Answer.PASS, capture(allowed = true).up(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
    }

    // ---- a listener that should no longer listen -----------------------------

    @Test
    fun `a capture not listening yet passes PREVIOUS without reading the gate`() {
        val capture = MediaKeyCapture {
            gateReads++
            true
        }

        assertEquals(MediaKeyCapture.Answer.PASS, capture.down(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
        assertEquals(MediaKeyCapture.Answer.PASS, capture.up(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
        assertEquals(0, gateReads)
    }

    @Test
    fun `once it stops listening PREVIOUS is the player's again, though the system still calls it`() {
        // The system can keep the listener after the mode is turned off: the
        // unregistering call needs the grant, so after a revoke it fails.
        val capture = capture(allowed = true)
        assertEquals(MediaKeyCapture.Answer.PRESS, capture.down(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
        assertEquals(MediaKeyCapture.Answer.CONSUME, capture.up(KeyEvent.KEYCODE_MEDIA_PREVIOUS))

        capture.listening = false

        assertEquals(MediaKeyCapture.Answer.PASS, capture.down(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
        assertEquals(MediaKeyCapture.Answer.PASS, capture.down(KeyEvent.KEYCODE_MEDIA_PREVIOUS, repeat = 1))
        assertEquals(MediaKeyCapture.Answer.PASS, capture.up(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
        assertEquals(1, gateReads)
    }

    @Test
    fun `a press kept before it stopped listening does not keep a later press`() {
        val capture = capture(allowed = true)
        capture.down(KeyEvent.KEYCODE_MEDIA_PREVIOUS)

        capture.listening = false
        capture.up(KeyEvent.KEYCODE_MEDIA_PREVIOUS)
        capture.listening = true

        assertEquals(MediaKeyCapture.Answer.PASS, capture.up(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
    }

    @Test
    fun `each press asks the gate afresh, so a kept press does not keep the next one`() {
        var allowed = true
        val capture = MediaKeyCapture { allowed }.apply { listening = true }
        assertEquals(MediaKeyCapture.Answer.PRESS, capture.down(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
        assertEquals(MediaKeyCapture.Answer.CONSUME, capture.up(KeyEvent.KEYCODE_MEDIA_PREVIOUS))

        allowed = false

        assertEquals(MediaKeyCapture.Answer.PASS, capture.down(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
        assertEquals(MediaKeyCapture.Answer.PASS, capture.up(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
    }

    @Test
    fun `an UP of another key between a kept DOWN and its UP leaves the pair intact`() {
        val capture = capture(allowed = true)
        capture.down(KeyEvent.KEYCODE_MEDIA_PREVIOUS)

        assertEquals(MediaKeyCapture.Answer.PASS, capture.up(KeyEvent.KEYCODE_MEDIA_NEXT))
        assertEquals(MediaKeyCapture.Answer.CONSUME, capture.up(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
    }

    @Test
    fun `a kept press ends at its UP, so a second UP after it is the player's`() {
        val capture = capture(allowed = true)
        capture.down(KeyEvent.KEYCODE_MEDIA_PREVIOUS)
        capture.up(KeyEvent.KEYCODE_MEDIA_PREVIOUS)

        assertEquals(MediaKeyCapture.Answer.PASS, capture.up(KeyEvent.KEYCODE_MEDIA_PREVIOUS))
        assertEquals(MediaKeyCapture.Answer.PASS, capture.down(KeyEvent.KEYCODE_MEDIA_PREVIOUS, repeat = 1))
    }

    // ---- the slot self-probe ------------------------------------------------

    @Test
    fun `the probe's RECORD keys are claimed by their eventTime, and a claimed probe proves the slot`() {
        val probe = SlotProbe()
        probe.begin(eventTime = 7_000L)

        assertTrue(probe.claims(KeyEvent.KEYCODE_MEDIA_RECORD, 7_000L))
        assertTrue(probe.claims(KeyEvent.KEYCODE_MEDIA_RECORD, 7_000L))
        assertTrue(probe.conclude())
    }

    @Test
    fun `a probe that never came back says another app holds the slot`() {
        val probe = SlotProbe()
        probe.begin(eventTime = 7_000L)

        assertFalse(probe.conclude())
    }

    @Test
    fun `a RECORD key at another eventTime is the user's, not the probe's`() {
        val probe = SlotProbe()
        probe.begin(eventTime = 7_000L)

        assertFalse(probe.claims(KeyEvent.KEYCODE_MEDIA_RECORD, 7_001L))
        assertFalse(probe.claims(KeyEvent.KEYCODE_MEDIA_PREVIOUS, 7_000L))
        assertFalse(probe.conclude())
    }

    @Test
    fun `with no probe sent, no key is claimed`() {
        assertFalse(SlotProbe().claims(KeyEvent.KEYCODE_MEDIA_RECORD, 0L))
    }

    @Test
    fun `a new probe forgets what the last one saw`() {
        val probe = SlotProbe()
        probe.begin(eventTime = 7_000L)
        probe.claims(KeyEvent.KEYCODE_MEDIA_RECORD, 7_000L)
        assertTrue(probe.conclude())

        probe.begin(eventTime = 9_000L)

        assertFalse(probe.claims(KeyEvent.KEYCODE_MEDIA_RECORD, 7_000L))
        assertFalse(probe.conclude())
    }

    // ---- what counts as a Bluetooth audio output ---------------------------

    @Test
    fun `media-audio Bluetooth outputs count, classic and LE alike`() {
        listOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_HEARING_AID,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
            AudioDeviceInfo.TYPE_BLE_SPEAKER,
            AudioDeviceInfo.TYPE_BLE_BROADCAST,
        ).forEach { assertTrue("type $it", BluetoothAudioOutput.counts(it)) }
    }

    @Test
    fun `the phone's speaker, wired and USB headsets and call-only SCO do not count`() {
        listOf(
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        ).forEach { assertFalse("type $it", BluetoothAudioOutput.counts(it)) }
    }

    // ---- failure -> status --------------------------------------------------

    private fun status(
        enabled: Boolean = true,
        apiAvailable: Boolean = true,
        granted: Boolean = true,
        notificationAccess: Boolean = true,
        listenerRunning: Boolean = true,
        slotOwned: Boolean? = true,
        bluetoothOutput: Boolean = true,
    ) = TripleTapStatus.of(enabled, apiAvailable, granted, notificationAccess, listenerRunning, slotOwned, bluetoothOutput)

    @Test
    fun `with everything in place the mode is active`() {
        assertEquals(TripleTapStatus.ACTIVE, status())
    }

    @Test
    fun `each missing piece is named on its own`() {
        assertEquals(TripleTapStatus.OFF, status(enabled = false))
        assertEquals(TripleTapStatus.UNAVAILABLE, status(apiAvailable = false))
        assertEquals(TripleTapStatus.NOT_GRANTED, status(granted = false))
        assertEquals(TripleTapStatus.NEEDS_NOTIFICATION_ACCESS, status(notificationAccess = false))
        assertEquals(TripleTapStatus.LISTENER_OFF, status(listenerRunning = false))
        assertEquals(TripleTapStatus.SLOT_TAKEN, status(slotOwned = false))
        assertEquals(TripleTapStatus.NO_BLUETOOTH_OUTPUT, status(bluetoothOutput = false))
    }

    @Test
    fun `the status names what to fix first, in the order off, unavailable, grant, access, listener, slot, Bluetooth`() {
        assertEquals(
            TripleTapStatus.OFF,
            status(
                enabled = false, apiAvailable = false, granted = false, notificationAccess = false,
                listenerRunning = false, slotOwned = false, bluetoothOutput = false,
            ),
        )
        assertEquals(
            TripleTapStatus.UNAVAILABLE,
            status(
                apiAvailable = false, granted = false, notificationAccess = false,
                listenerRunning = false, slotOwned = false, bluetoothOutput = false,
            ),
        )
        assertEquals(
            TripleTapStatus.NOT_GRANTED,
            status(granted = false, notificationAccess = false, listenerRunning = false, slotOwned = false, bluetoothOutput = false),
        )
        assertEquals(
            TripleTapStatus.NEEDS_NOTIFICATION_ACCESS,
            status(notificationAccess = false, listenerRunning = false, slotOwned = false, bluetoothOutput = false),
        )
        assertEquals(
            TripleTapStatus.LISTENER_OFF,
            status(listenerRunning = false, slotOwned = false, bluetoothOutput = false),
        )
        assertEquals(TripleTapStatus.SLOT_TAKEN, status(slotOwned = false, bluetoothOutput = false))
    }

    @Test
    fun `a slot nobody has probed yet is not reported as taken`() {
        assertEquals(TripleTapStatus.ACTIVE, status(slotOwned = null))
    }

    @Test
    fun `the status crosses the method channel as these names, which the Dart side parses`() {
        val wire = TripleTapStatus.values().associate { it to it.wire }
        assertEquals(
            mapOf(
                TripleTapStatus.OFF to "off",
                TripleTapStatus.UNAVAILABLE to "unavailable",
                TripleTapStatus.NOT_GRANTED to "not_granted",
                TripleTapStatus.NEEDS_NOTIFICATION_ACCESS to "needs_notification_access",
                TripleTapStatus.LISTENER_OFF to "listener_off",
                TripleTapStatus.SLOT_TAKEN to "slot_taken",
                TripleTapStatus.NO_BLUETOOTH_OUTPUT to "no_bluetooth_output",
                TripleTapStatus.ACTIVE to "active",
            ),
            wire,
        )
    }

    @Test
    fun `a refused registration is a missing grant, whether thrown direct or through reflection`() {
        val viaReflection = java.lang.reflect.InvocationTargetException(SecurityException("no SET_MEDIA_KEY_LISTENER"))

        assertEquals(RegistrationFailure.NOT_GRANTED, RegistrationFailure.of(viaReflection))
        assertEquals(RegistrationFailure.NOT_GRANTED, RegistrationFailure.of(SecurityException("denied")))
    }

    @Test
    fun `any other registration failure means the hidden API is unavailable on this build`() {
        assertEquals(RegistrationFailure.UNAVAILABLE, RegistrationFailure.of(ClassNotFoundException("OnMediaKeyListener")))
        assertEquals(RegistrationFailure.UNAVAILABLE, RegistrationFailure.of(NoSuchMethodException("setOnMediaKeyListener")))
        assertEquals(
            RegistrationFailure.UNAVAILABLE,
            RegistrationFailure.of(java.lang.reflect.InvocationTargetException(IllegalStateException("changed"))),
        )
    }
}
