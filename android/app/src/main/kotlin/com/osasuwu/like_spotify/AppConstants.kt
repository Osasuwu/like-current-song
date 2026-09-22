package com.osasuwu.like_spotify

import android.content.SharedPreferences

object AppConstants {
    const val PREFS = "like_spotify_prefs"
    const val KEY_SERVICE_ENABLED = "service_enabled"
    const val KEY_PATTERN = "trigger_pattern"
    const val KEY_WINDOW_MS = "trigger_window_ms"
    const val KEY_DEBOUNCE_MS = "trigger_debounce_ms"
    const val KEY_FEEDBACK_VOLUME = "trigger_feedback_volume"
    const val DEFAULT_FEEDBACK_VOLUME = 100

    /** Selected music service id ("spotify" | "ytmusic"); see [MusicProvider]. */
    const val KEY_MUSIC_PROVIDER = "music_provider"

    /**
     * How likes are routed ("picker" | "automatic"); see
     * [MusicRoutingMode]. Absent means "picker", so an install
     * upgraded from a build without automatic routing keeps its picked
     * service until the user opts in.
     */
    const val KEY_MUSIC_ROUTING_MODE = "music_routing_mode"

    /**
     * Id of the provider whose media session was last seen playing, written
     * by [PlaybackNotificationListenerService]. Automatic routing falls back
     * to it when nothing is playing right now.
     */
    const val KEY_LAST_PLAYING_PROVIDER = "last_playing_provider"

    const val KEY_SPOTIFY_ACCESS_TOKEN = "spotify_access_token"
    const val KEY_SPOTIFY_REFRESH_TOKEN = "spotify_refresh_token"
    const val KEY_SPOTIFY_EXPIRES_AT = "spotify_expires_at"
    const val KEY_SPOTIFY_CLIENT_ID = "spotify_client_id"
    const val KEY_SPOTIFY_USER_ID = "spotify_user_id"

    // YouTube Music (Google device-flow sign-in). Written by Dart via
    // `syncYouTubeMusicTokens`; the native side writes refreshed tokens back
    // to the same keys. Expiry is epoch milliseconds.
    const val KEY_YTM_ACCESS_TOKEN = "ytm_access_token"
    const val KEY_YTM_REFRESH_TOKEN = "ytm_refresh_token"
    const val KEY_YTM_TOKEN_EXPIRES_AT = "ytm_token_expires_at"
    const val KEY_YTM_CLIENT_ID = "ytm_client_id"
    const val KEY_YTM_CLIENT_SECRET = "ytm_client_secret"
    const val KEY_YTM_USER_SUB = "ytm_user_sub"

    /**
     * Where a like goes ("native" | "playlist" | "both"); see [LikeDestination].
     * Absent means "native", so an install upgraded from a build without the
     * setting keeps liking exactly as it did.
     */
    const val KEY_RULE_LIKE_DESTINATION = "rule_like_destination"

    /** Playlist a like is added to, matched by name on the selected service. */
    const val KEY_RULE_LIKE_PLAYLIST_NAME = "rule_like_playlist_name"

    const val KEY_RULE_ARCHIVE_REMOVE_ENABLED = "rule_archive_remove_enabled"
    const val KEY_RULE_ARCHIVE_PLAYLIST_NAME = "rule_archive_playlist_name"
    const val KEY_RULE_BEST_ENABLED = "rule_best_enabled"
    const val KEY_RULE_BEST_PLAYLIST_NAME = "rule_best_playlist_name"
    const val KEY_RULE_BEST_THRESHOLD = "rule_best_threshold"

    // Spellings used up to v1.1.0, when the rule was called "best-of". Read as a
    // fallback so an upgrade keeps the saved rule; never written again.
    const val LEGACY_KEY_RULE_BEST_ENABLED = "rule_best_of_enabled"
    const val LEGACY_KEY_RULE_BEST_PLAYLIST_NAME = "rule_best_of_playlist_name"
    const val LEGACY_KEY_RULE_BEST_THRESHOLD = "rule_best_of_threshold"

    const val KEY_RULE_FOLLOW_ARTIST_ENABLED = "rule_follow_artist_enabled"
    const val KEY_RULE_FOLLOW_ARTIST_THRESHOLD = "rule_follow_artist_threshold"
    const val KEY_RULE_LIKE_COOLDOWN_ENABLED = "rule_like_cooldown_enabled"
    const val KEY_RULE_LIKE_COOLDOWN_MINUTES = "rule_like_cooldown_minutes"

    const val DEFAULT_BEST_THRESHOLD = 3
    const val DEFAULT_FOLLOW_ARTIST_THRESHOLD = 5
    const val DEFAULT_LIKE_COOLDOWN_MINUTES = 10

    const val KEY_TRACK_LIKE_COUNTS = "track_like_counts"
    const val KEY_ARTIST_LIKE_COUNTS = "artist_like_counts"
    const val KEY_TRACK_LAST_LIKED_AT = "track_last_liked_at"
    const val KEY_PLAYLIST_CACHE = "playlist_cache"
    const val KEY_PLAYLIST_CACHE_TIMESTAMP = "playlist_cache_timestamp"

    // Playlist name -> id for YouTube Music. A separate cache from Spotify's:
    // the same playlist name means a different id on each service.
    const val KEY_YTM_PLAYLIST_CACHE = "ytm_playlist_cache"
    const val KEY_YTM_PLAYLIST_CACHE_TIMESTAMP = "ytm_playlist_cache_timestamp"

    // The shared like counter: a Google Sheet the user owns, plus its own
    // Google sign-in (independent of the music service, so the counter works
    // whichever service is picked). Written by Dart via `setLikeCounterConfig`;
    // the native side writes refreshed tokens back to the same keys. Expiry is
    // epoch milliseconds.
    const val KEY_COUNTER_SPREADSHEET_ID = "counter_spreadsheet_id"
    const val KEY_COUNTER_CLIENT_ID = "counter_google_client_id"
    const val KEY_COUNTER_CLIENT_SECRET = "counter_google_client_secret"
    const val KEY_COUNTER_ACCESS_TOKEN = "counter_google_access"
    const val KEY_COUNTER_REFRESH_TOKEN = "counter_google_refresh"
    const val KEY_COUNTER_TOKEN_EXPIRES_AT = "counter_google_expiry_epoch_ms"

    const val PLAYLIST_CACHE_TTL_MS = 12 * 60 * 60 * 1000L  // 12 hours

    /** Background log events that found no live Flutter engine; see [BackgroundLog]. */
    const val KEY_BACKGROUND_LOG = "background_log_buffer"

    /**
     * How many background events survive at once. The app can stay closed for
     * days, so the buffer has to be bounded; at roughly six events per like
     * this still covers a long stretch of presses, and the oldest go first.
     */
    const val BACKGROUND_LOG_MAX_ENTRIES = 200

    const val ACTION_MEDIA_EVENT = "com.osasuwu.like_spotify.MEDIA_EVENT"
    const val ACTION_LOG_EVENT = "com.osasuwu.like_spotify.LOG_EVENT"
    const val ACTION_SERVICE_STATE = "com.osasuwu.like_spotify.SERVICE_STATE"
    const val ACTION_TRIGGER_LIKE = "com.osasuwu.like_spotify.TRIGGER_LIKE"

    /**
     * Notification access was granted or revoked. In-process only (everything
     * here shares one process), so the foreground service can re-word its
     * notification the moment the grant it depends on changes.
     */
    const val ACTION_LISTENER_STATE_CHANGED =
        "com.osasuwu.like_spotify.LISTENER_STATE_CHANGED"

    const val EXTRA_EVENT = "event"
    const val EXTRA_LOG = "log"
    const val EXTRA_ACTIVE = "active"
    const val EXTRA_LOG_ACTION_TYPE = "log_action_type"
    const val EXTRA_LOG_TARGET_ID = "log_target_id"
    const val EXTRA_LOG_RESULT = "log_result"
    const val EXTRA_LOG_HTTP_CODE = "log_http_code"

    const val CHANNEL_SERVICE = "like_spotify_mobile_app/service"
    const val CHANNEL_EVENTS = "like_spotify_mobile_app/events"

    const val NOTIFICATION_CHANNEL_ID = "like_spotify_service"
    const val NOTIFICATION_CHANNEL_NAME = "Like Current Song listener"
    const val NOTIFICATION_ID = 11001

    const val ACCOUNT_NOTIFICATION_CHANNEL_ID = "like_spotify_account"
    const val ACCOUNT_NOTIFICATION_CHANNEL_NAME = "Account sign-in"
    const val YTM_REAUTH_NOTIFICATION_ID = 11002

    /**
     * Reads the "promote to best playlist" rule, falling back to the pre-v1.1.1
     * `rule_best_of_*` keys so an upgraded install keeps the rule it saved.
     * Only the current keys are ever written back (see MainActivity).
     */
    fun bestRuleEnabled(prefs: SharedPreferences): Boolean = when {
        prefs.contains(KEY_RULE_BEST_ENABLED) -> prefs.getBoolean(KEY_RULE_BEST_ENABLED, false)
        else -> prefs.getBoolean(LEGACY_KEY_RULE_BEST_ENABLED, false)
    }

    fun bestRulePlaylistName(prefs: SharedPreferences): String = when {
        prefs.contains(KEY_RULE_BEST_PLAYLIST_NAME) -> prefs.getString(KEY_RULE_BEST_PLAYLIST_NAME, null)
        else -> prefs.getString(LEGACY_KEY_RULE_BEST_PLAYLIST_NAME, null)
    }?.trim().orEmpty()

    /** The like playlist name, trimmed; empty when none is configured. */
    fun likeRulePlaylistName(prefs: SharedPreferences): String =
        prefs.getString(KEY_RULE_LIKE_PLAYLIST_NAME, null)?.trim().orEmpty()

    /**
     * Where likes go, already reconciled with the playlist name: a playlist
     * destination without a name falls back to the service's own like.
     */
    fun likeRuleDestination(prefs: SharedPreferences): LikeDestination =
        LikeDestination.resolve(
            prefs.getString(KEY_RULE_LIKE_DESTINATION, null),
            likeRulePlaylistName(prefs),
        )

    fun bestRuleThreshold(prefs: SharedPreferences): Int = when {
        prefs.contains(KEY_RULE_BEST_THRESHOLD) -> prefs.getInt(KEY_RULE_BEST_THRESHOLD, DEFAULT_BEST_THRESHOLD)
        else -> prefs.getInt(LEGACY_KEY_RULE_BEST_THRESHOLD, DEFAULT_BEST_THRESHOLD)
    }.takeIf { it >= 1 } ?: DEFAULT_BEST_THRESHOLD
}
