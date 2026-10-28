package com.osasuwu.like_spotify

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

object FeedbackPlayer {
    // Headroom before release(): releasing as soon as playback is due to end
    // truncated the tone to its first buffer on HyperOS 3 / Android 16 (seen
    // with ToneGenerator; kept for AudioTrack, which buffers the same way).
    private const val RELEASE_HEADROOM_MS = 150L

    fun play(context: Context, success: Boolean) =
        play(context, if (success) FeedbackKind.LIKE else FeedbackKind.ERROR)

    fun play(context: Context, kind: FeedbackKind) {
        runCatching { playTone(context, kind) }
        runCatching { vibrate(context, kind) }
    }

    private fun playTone(context: Context, kind: FeedbackKind) {
        val prefs = context.getSharedPreferences(AppConstants.PREFS, Context.MODE_PRIVATE)
        val volume = prefs.getInt(AppConstants.KEY_FEEDBACK_VOLUME, AppConstants.DEFAULT_FEEDBACK_VOLUME)
        val segments = FeedbackTones.segments(kind)
        val pcm = FeedbackTones.synth(segments, volume / 100.0)
        // Synthesized rather than ToneGenerator presets, so the phone plays the
        // same tones as the desktop (FeedbackTones). USAGE_MEDIA keeps the
        // STREAM_MUSIC routing ToneGenerator had: it mixes over the music.
        val track = AudioTrack(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build(),
            AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(FeedbackTones.SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build(),
            pcm.size * 2,
            AudioTrack.MODE_STATIC,
            AudioManager.AUDIO_SESSION_ID_GENERATE,
        )
        try {
            track.write(pcm, 0, pcm.size)
            track.play()
        } catch (e: Exception) {
            track.release()
            throw e
        }
        Handler(Looper.getMainLooper()).postDelayed(
            { track.release() },
            FeedbackTones.durationMs(segments) + RELEASE_HEADROOM_MS,
        )
    }

    private fun vibrate(context: Context, kind: FeedbackKind) {
        @Suppress("DEPRECATION")
        val vibrator: Vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            vibrator.vibrate(
                when (kind) {
                    FeedbackKind.LIKE -> 120L
                    FeedbackKind.ERROR -> 240L
                    FeedbackKind.UNDO -> 320L
                }
            )
            return
        }
        val effect = when (kind) {
            FeedbackKind.LIKE -> VibrationEffect.createOneShot(120, VibrationEffect.DEFAULT_AMPLITUDE)
            FeedbackKind.ERROR -> VibrationEffect.createWaveform(longArrayOf(0, 80, 80, 80), -1)
            // Long then short: unlike the error's two equal pulses.
            FeedbackKind.UNDO -> VibrationEffect.createWaveform(longArrayOf(0, 200, 60, 60), -1)
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
    }
}
