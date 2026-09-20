package com.osasuwu.like_spotify

import android.content.ComponentName
import android.content.Context
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState

/** How a like picks its music service. Mirrors Dart's `MusicRoutingMode`. */
enum class MusicRoutingMode(val id: String) {
    PICKER("picker"),
    AUTOMATIC("automatic");

    companion object {
        /**
         * Absent or unknown means the picker, so an install upgraded from a
         * build without automatic routing keeps its explicit service until the
         * user opts in.
         */
        val DEFAULT = PICKER

        fun fromId(id: String?): MusicRoutingMode =
            values().firstOrNull { it.id == id } ?: DEFAULT
    }
}

/**
 * Why [MusicProvider.resolve] chose the service it chose. The labels are the
 * ones the Logs screen shows, and match Dart's `MusicRoutingReason`.
 */
enum class MusicRoutingReason(val label: String) {
    PICKER("picker"),
    PLAYING_SESSION("playing session"),
    LAST_PLAYING("last playing"),
    PICKER_FALLBACK("picker fallback"),
}

/** A routing decision: the service a like goes to, and why. */
data class MusicRouting(
    val provider: MusicProvider,
    val reason: MusicRoutingReason,
) {
    /** False only for an explicit pick, which is not worth logging. */
    val automatic: Boolean get() = reason != MusicRoutingReason.PICKER

    /** Same sentence Dart logs, so both paths read alike in the log. */
    fun logLine(): String = "Automatic routing -> ${provider.displayName} (${reason.label})"
}

/**
 * The music service likes go to. Mirrors `MusicProvider` in
 * `lib/domain/entities/music_provider.dart`; ids match the desktop
 * `music.provider` config values.
 *
 * Flutter writes the selection to [AppConstants.KEY_MUSIC_PROVIDER] via the
 * `setMusicProvider` channel method and the routing mode to
 * [AppConstants.KEY_MUSIC_ROUTING_MODE] via `setMusicRoutingMode`.
 *
 * This is the one native place that decides where a like goes: [resolve] is
 * the whole rule, and it is the same rule as
 * `ActiveMusicServiceRepository.resolveRouting` in Dart. Change one, change
 * the other. It lives natively because the trigger usually fires with the
 * Flutter engine detached ([MediaButtonForegroundService.likeInBackground]).
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

    /** Whether this service is signed in, i.e. a like sent to it could work. */
    fun isConnected(context: Context): Boolean {
        val prefs = context.getSharedPreferences(AppConstants.PREFS, Context.MODE_PRIVATE)
        val key = when (this) {
            SPOTIFY -> AppConstants.KEY_SPOTIFY_ACCESS_TOKEN
            YTMUSIC -> AppConstants.KEY_YTM_ACCESS_TOKEN
        }
        return !prefs.getString(key, null).isNullOrBlank()
    }

    companion object {
        val DEFAULT = SPOTIFY

        fun fromId(id: String?): MusicProvider =
            values().firstOrNull { it.id == id } ?: DEFAULT

        /** The explicitly picked service, ignoring automatic routing. */
        fun current(context: Context): MusicProvider =
            fromId(prefs(context).getString(AppConstants.KEY_MUSIC_PROVIDER, null))

        fun routingMode(context: Context): MusicRoutingMode =
            MusicRoutingMode.fromId(
                prefs(context).getString(AppConstants.KEY_MUSIC_ROUTING_MODE, null)
            )

        fun connected(context: Context): List<MusicProvider> =
            values().filter { it.isConnected(context) }

        /**
         * Where a like goes, in order:
         *
         * 1. picker mode — the picked service, always;
         * 2. exactly one connected service owns a `STATE_PLAYING` session — it;
         * 3. otherwise the connected service seen playing most recently;
         * 4. otherwise the picked service.
         *
         * Steps 2-4 only run in automatic mode, which the UI offers only with
         * notification access granted and two services connected. Nothing here
         * can fail closed onto a service that is not signed in.
         */
        fun resolve(context: Context): MusicRouting {
            val picked = current(context)
            if (routingMode(context) != MusicRoutingMode.AUTOMATIC) {
                return MusicRouting(picked, MusicRoutingReason.PICKER)
            }
            val connected = connected(context)
            val playing = playing(context).filter { it in connected }
            // Two at once says nothing about which one the user means.
            if (playing.size == 1) {
                return MusicRouting(playing.single(), MusicRoutingReason.PLAYING_SESSION)
            }
            val last = lastPlaying(context)
            if (last != null && last in connected) {
                return MusicRouting(last, MusicRoutingReason.LAST_PLAYING)
            }
            return MusicRouting(picked, MusicRoutingReason.PICKER_FALLBACK)
        }

        /**
         * Whether a playback event from [pkg] should drive the trigger. In
         * automatic mode any connected service's session counts, otherwise
         * only the picked one's — a pattern on the other service would
         * otherwise never reach the detector.
         */
        fun listensTo(context: Context, pkg: String): Boolean =
            if (routingMode(context) == MusicRoutingMode.AUTOMATIC) {
                values().any { it.isConnected(context) && it.ownsSession(pkg) }
            } else {
                current(context).ownsSession(pkg)
            }

        /**
         * Services that own a `STATE_PLAYING` media session right now.
         *
         * Reading sessions needs notification access; without it
         * [MediaSessionManager.getActiveSessions] throws, which is a
         * legitimate state (Spotify works without the permission) and means
         * "nothing known to be playing", not an error.
         */
        fun playing(context: Context): List<MusicProvider> {
            val manager = context.getSystemService(Context.MEDIA_SESSION_SERVICE)
                as? MediaSessionManager ?: return emptyList()
            val component = ComponentName(
                context,
                PlaybackNotificationListenerService::class.java
            )
            val controllers = runCatching { manager.getActiveSessions(component) }
                .getOrDefault(emptyList())
            return controllers
                .filter { it.playbackState?.state == PlaybackState.STATE_PLAYING }
                .mapNotNull { controller ->
                    values().firstOrNull { it.ownsSession(controller.packageName) }
                }
                .distinct()
        }

        /** The service last seen playing, or null if none has been. */
        fun lastPlaying(context: Context): MusicProvider? {
            val id = prefs(context).getString(AppConstants.KEY_LAST_PLAYING_PROVIDER, null)
                ?: return null
            // Not [fromId]: an unknown id must stay unknown here rather than
            // become Spotify, or step 3 would answer when it should not.
            return values().firstOrNull { it.id == id }
        }

        /** Remembers [provider] as the one playing, for [lastPlaying]. */
        fun recordPlaying(context: Context, provider: MusicProvider) {
            prefs(context).edit()
                .putString(AppConstants.KEY_LAST_PLAYING_PROVIDER, provider.id)
                .apply()
        }

        private fun prefs(context: Context) =
            context.getSharedPreferences(AppConstants.PREFS, Context.MODE_PRIVATE)
    }
}
