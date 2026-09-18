package com.osasuwu.like_spotify

import android.content.Context
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

object FeedbackPlayer {
    fun play(context: Context, success: Boolean) {
        runCatching {
            val prefs = context.getSharedPreferences(AppConstants.PREFS, Context.MODE_PRIVATE)
            val volume = prefs.getInt(AppConstants.KEY_FEEDBACK_VOLUME, AppConstants.DEFAULT_FEEDBACK_VOLUME)
            val tone = ToneGenerator(AudioManager.STREAM_MUSIC, volume)
            val toneType = if (success) ToneGenerator.TONE_PROP_ACK else ToneGenerator.TONE_PROP_NACK
            tone.startTone(toneType, 180)
            tone.release()
        }.onFailure { error -> logFailure(context, "tone", error) }
        runCatching {
            @Suppress("DEPRECATION")
            val vibrator: Vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
            } else {
                context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val effect = if (success) {
                    VibrationEffect.createOneShot(120, VibrationEffect.DEFAULT_AMPLITUDE)
                } else {
                    VibrationEffect.createWaveform(longArrayOf(0, 80, 80, 80), -1)
                }
                vibrator.vibrate(effect)
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(if (success) 120L else 240L)
            }
        }.onFailure { error -> logFailure(context, "vibration", error) }
    }

    // Feedback failures were previously swallowed silently (runCatching with no
    // handler), so a broken tone/vibrator on a given device left no trace anywhere —
    // not even in the in-app Logs screen. Surface them the same way the rest of the
    // native path reports events, so a silent feedback failure is diagnosable.
    private fun logFailure(context: Context, kind: String, error: Throwable) {
        val intent = android.content.Intent(AppConstants.ACTION_LOG_EVENT)
            .putExtra(AppConstants.EXTRA_LOG, "Feedback $kind failed: ${error.message ?: error::class.java.simpleName}")
            .putExtra(AppConstants.EXTRA_LOG_ACTION_TYPE, "feedback_$kind")
            .putExtra(AppConstants.EXTRA_LOG_RESULT, "failure")
        androidx.localbroadcastmanager.content.LocalBroadcastManager
            .getInstance(context.applicationContext)
            .sendBroadcast(intent)
    }
}
