package com.osasuwu.like_spotify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootCompletedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_LOCKED_BOOT_COMPLETED) {
            return
        }
        val prefs = context.getSharedPreferences(AppConstants.PREFS, Context.MODE_PRIVATE)
        val enabled = prefs.getBoolean(AppConstants.KEY_SERVICE_ENABLED, false)
        if (!enabled) {
            return
        }
        val serviceIntent = Intent(context, MediaButtonForegroundService::class.java).apply {
            action = MediaButtonForegroundService.ACTION_START
        }
        // Deliberately not `context.startForegroundService` directly: a refusal
        // here would be an uncaught crash while the device is booting. The
        // service is declared specialUse precisely so this start is permitted
        // on Android 15+ (mediaPlayback would be refused outright), but OEM
        // policy can still say no. `service_enabled` stays set either way, so
        // opening the app restarts the listener.
        MediaButtonForegroundService.start(context, serviceIntent)
    }
}
