package com.osasuwu.like_spotify

/**
 * Where a like goes: the service's own "liked songs", a playlist of the
 * user's own, or both.
 *
 * The Kotlin twin of the Dart `LikeDestination`; [id] is the same string on
 * both sides, so the value Dart writes to SharedPreferences reads back here
 * unchanged. Deliberately pure — no Android API — so both native like paths
 * (the Spotify worker and the YouTube Music liker) share one implementation
 * of the branching, and a JUnit test can reach it.
 */
enum class LikeDestination(val id: String) {
    NATIVE("native"),
    PLAYLIST("playlist"),
    BOTH("both");

    /** Whether the service's own like should be sent. */
    val likesNatively: Boolean get() = this != PLAYLIST

    /** Whether the track should be added to the user's like playlist. */
    val addsToPlaylist: Boolean get() = this != NATIVE

    companion object {
        /** New installs, and installs that predate the setting, like natively. */
        val DEFAULT = NATIVE

        /** Unknown or missing ids fall back to [DEFAULT]. */
        fun fromId(id: String?): LikeDestination =
            values().firstOrNull { it.id == id } ?: DEFAULT

        /**
         * The destination to actually run, given the configured playlist name.
         *
         * A playlist destination with no playlist name has nowhere to put the
         * song. The settings screen refuses to save such a config, so this only
         * catches one written by an older build or by hand: rather than failing
         * every like, it falls back to the service's own like.
         */
        fun resolve(id: String?, playlistName: String): LikeDestination {
            val destination = fromId(id)
            return if (destination.addsToPlaylist && playlistName.isBlank()) NATIVE else destination
        }

        /**
         * Whether the like as a whole counted.
         *
         * A one-leg destination is exactly as good as its leg. [BOTH] wants the
         * song liked in two places but one is enough for it to be liked at all,
         * so it only fails when both legs fail.
         */
        fun succeeded(destination: LikeDestination, nativeOk: Boolean, playlistOk: Boolean): Boolean =
            when (destination) {
                NATIVE -> nativeOk
                PLAYLIST -> playlistOk
                BOTH -> nativeOk || playlistOk
            }
    }
}
