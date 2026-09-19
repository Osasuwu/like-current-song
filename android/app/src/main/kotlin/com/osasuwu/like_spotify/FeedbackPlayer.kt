package com.osasuwu.like_spotify

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

object FeedbackPlayer {
    private const val TONE_DURATION_MS = 180
    // Headroom before release(): releasing right after startTone() truncates the
    // tone to its first buffer (~20 ms) on HyperOS 3 / Android 16.
    private const val TONE_RELEASE_DELAY_MS = TONE_DURATION_MS + 150L

    fun play(context: Context, success: Boolean) {
        runCatching {
            val prefs = context.getSharedPreferences(AppConstants.PREFS, Context.MODE_PRIVATE)
            val volume = prefs.getInt(AppConstants.KEY_FEEDBACK_VOLUME, AppConstants.DEFAULT_FEEDBACK_VOLUME)
            val tone = ToneGenerator(AudioManager.STREAM_MUSIC, volume)
            val toneType = if (success) ToneGenerator.TONE_PROP_ACK else ToneGenerator.TONE_PROP_NACK
            tone.startTone(toneType, TONE_DURATION_MS)
            Handler(Looper.getMainLooper()).postDelayed({ tone.release() }, TONE_RELEASE_DELAY_MS)
        }
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
                // Tag as media feedback: untagged vibrations default to USAGE_TOUCH,
                // which is dropped when the user disables touch haptics.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    vibrator.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_MEDIA))
                } else {
                    @Suppress("DEPRECATION")
                    vibrator.vibrate(
                        effect,
                        AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).build()
                    )
                }
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(if (success) 120L else 240L)
            }
        }
    }
}
