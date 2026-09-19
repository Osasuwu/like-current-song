package com.osasuwu.like_spotify

import android.content.Context

/**
 * The music service likes go to. Mirrors `MusicProvider` in
 * `lib/domain/entities/music_provider.dart`; ids match the desktop
 * `music.provider` config values.
 *
 * Flutter writes the selection to [AppConstants.KEY_MUSIC_PROVIDER] via the
 * `setMusicProvider` channel method; the service, worker and notification
 * listener read it with [current].
 */
enum class MusicProvider(
    val id: String,
    val displayName: String,
    val packageName: String,
) {
    SPOTIFY("spotify", "Spotify", "com.spotify.music"),
    YTMUSIC("ytmusic", "YouTube Music", "com.google.android.apps.youtube.music");

    /** Whether a media session / notification from [pkg] belongs to this service. */
    fun ownsSession(pkg: String): Boolean = when (this) {
        // Kept loose as before: Spotify has shipped under more than one package id.
        SPOTIFY -> pkg.contains("spotify")
        YTMUSIC -> pkg == packageName
    }

    companion object {
        val DEFAULT = SPOTIFY

        fun fromId(id: String?): MusicProvider =
            values().firstOrNull { it.id == id } ?: DEFAULT

        fun current(context: Context): MusicProvider {
            val prefs = context.getSharedPreferences(AppConstants.PREFS, Context.MODE_PRIVATE)
            return fromId(prefs.getString(AppConstants.KEY_MUSIC_PROVIDER, null))
        }
    }
}
