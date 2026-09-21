package com.osasuwu.like_spotify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ServiceNotificationTextTest {

    @Test
    fun `with the grant it says it is listening`() {
        assertEquals(
            "Listening for headset pattern",
            ServiceNotificationText.body(listenerEnabled = true),
        )
        assertEquals(
            "Like Current Song is active",
            ServiceNotificationText.title(active = true, listenerEnabled = true),
        )
    }

    @Test
    fun `without the grant it never claims to be listening`() {
        // The bug in #153: this sentence was unconditional, and a user read it
        // as proof the app was working while nothing could reach it.
        val body = ServiceNotificationText.body(listenerEnabled = false)
        assertFalse(body.contains("Listening"))
        assertTrue(body.contains("Notification access"))
    }

    @Test
    fun `without the grant the service is not called active`() {
        // Not even when it is running: it runs and hears nothing.
        val title = ServiceNotificationText.title(active = true, listenerEnabled = false)
        assertFalse(title.contains("active"))
        assertEquals("Like Current Song is not listening", title)
    }

    @Test
    fun `the grant is what distinguishes inactive from unable to listen`() {
        assertEquals(
            "Like Current Song is inactive",
            ServiceNotificationText.title(active = false, listenerEnabled = true),
        )
    }
}
