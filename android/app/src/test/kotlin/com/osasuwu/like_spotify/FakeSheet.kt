package com.osasuwu.like_spotify

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * A stand-in for the Google Sheets API behind [LikeCounter]'s artist-tab
 * calls (#282): hand [open] to them as the connection opener. Every request
 * is answered by [answer] from its method and URL, without a socket, and
 * kept in [requests] with the body that was sent.
 */
class FakeSheet(private val answer: (method: String, url: String) -> Reply) {

    data class Reply(val status: Int, val body: String = "")

    data class Request(val method: String, val url: String, val body: String)

    val requests = mutableListOf<Request>()

    fun open(url: String): HttpURLConnection = Connection(URL(url))

    private inner class Connection(url: URL) : HttpURLConnection(url) {
        private val sent = ByteArrayOutputStream()
        private var reply: Reply? = null

        /** The request goes out the first time its answer is read, as on a device. */
        private fun reply(): Reply = reply ?: answer(requestMethod, url.toString()).also {
            requests += Request(requestMethod, url.toString(), sent.toString(Charsets.UTF_8.name()))
            reply = it
        }

        override fun getOutputStream(): OutputStream = sent
        override fun getResponseCode(): Int = reply().status
        override fun getInputStream(): InputStream = reply().body.byteInputStream()
        override fun connect() = Unit
        override fun disconnect() = Unit
        override fun usingProxy(): Boolean = false
    }

    companion object {
        /** Prefs holding a counter token that is not due a refresh, so no call goes to Google's token endpoint. */
        fun signedInPrefs(): FakeSharedPreferences = FakeSharedPreferences().apply {
            values[AppConstants.KEY_COUNTER_ACCESS_TOKEN] = "counter-token"
            values[AppConstants.KEY_COUNTER_TOKEN_EXPIRES_AT] = Long.MAX_VALUE
        }
    }
}
