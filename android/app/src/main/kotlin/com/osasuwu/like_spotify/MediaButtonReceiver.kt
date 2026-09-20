package com.osasuwu.like_spotify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.view.KeyEvent

/**
 * **Not the path the headset trigger takes.** Android delivers a media button
 * to the one session it considers the current player, so while music is
 * playing that is the music app and never us — and it has to be: the trigger is
 * pause → play, which only works if the press reaches the player and actually
 * pauses it. What the app reacts to is the *consequence*, read by
 * [PlaybackNotificationListenerService] from the player's playback state.
 *
 * This receiver therefore only fires when nothing else holds the media button,
 * i.e. when there is no playing track to like — a wired headset or a remote
 * pressed with no player running. It is kept for that case; treating it as the
 * working path is the mistake #153 was filed about.
 */
class MediaButtonReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (Intent.ACTION_MEDIA_BUTTON != intent.action) {
            return
        }
        val event = intent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT) ?: return
        if (event.action != KeyEvent.ACTION_DOWN) {
            return
        }

        val mapped = when (event.keyCode) {
            KeyEvent.KEYCODE_MEDIA_PLAY -> "play"
            KeyEvent.KEYCODE_MEDIA_PAUSE -> "pause"
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_HEADSETHOOK -> "toggle"
            else -> null
        } ?: return

        MediaButtonForegroundService.dispatchExternalMediaEvent(context, mapped)
    }
}
