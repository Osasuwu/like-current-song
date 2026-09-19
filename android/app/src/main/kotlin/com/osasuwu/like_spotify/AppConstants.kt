package com.osasuwu.like_spotify

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

    const val KEY_RULE_ARCHIVE_REMOVE_ENABLED = "rule_archive_remove_enabled"
    const val KEY_RULE_ARCHIVE_PLAYLIST_NAME = "rule_archive_playlist_name"
    const val KEY_RULE_BEST_OF_ENABLED = "rule_best_of_enabled"
    const val KEY_RULE_BEST_OF_PLAYLIST_NAME = "rule_best_of_playlist_name"
    const val KEY_RULE_BEST_OF_THRESHOLD = "rule_best_of_threshold"
    const val KEY_RULE_FOLLOW_ARTIST_ENABLED = "rule_follow_artist_enabled"
    const val KEY_RULE_FOLLOW_ARTIST_THRESHOLD = "rule_follow_artist_threshold"
    const val KEY_RULE_LIKE_COOLDOWN_ENABLED = "rule_like_cooldown_enabled"
    const val KEY_RULE_LIKE_COOLDOWN_MINUTES = "rule_like_cooldown_minutes"

    const val DEFAULT_ARCHIVE_PLAYLIST_NAME = "Discover Weekly Archive"
    const val DEFAULT_BEST_OF_PLAYLIST_NAME = "Botbotb(Best of the best of the best)"
    const val DEFAULT_BEST_OF_THRESHOLD = 3
    const val DEFAULT_FOLLOW_ARTIST_THRESHOLD = 5
    const val DEFAULT_LIKE_COOLDOWN_MINUTES = 10

    const val KEY_TRACK_LIKE_COUNTS = "track_like_counts"
    const val KEY_ARTIST_LIKE_COUNTS = "artist_like_counts"
    const val KEY_TRACK_LAST_LIKED_AT = "track_last_liked_at"
    const val KEY_PLAYLIST_CACHE = "playlist_cache"
    const val KEY_PLAYLIST_CACHE_TIMESTAMP = "playlist_cache_timestamp"
    const val KEY_SUPABASE_URL = "supabase_url"
    const val KEY_SUPABASE_ANON_KEY = "supabase_anon_key"
    const val PLAYLIST_CACHE_TTL_MS = 12 * 60 * 60 * 1000L  // 12 hours

    const val ACTION_MEDIA_EVENT = "com.osasuwu.like_spotify.MEDIA_EVENT"
    const val ACTION_LOG_EVENT = "com.osasuwu.like_spotify.LOG_EVENT"
    const val ACTION_SERVICE_STATE = "com.osasuwu.like_spotify.SERVICE_STATE"
    const val ACTION_TRIGGER_LIKE = "com.osasuwu.like_spotify.TRIGGER_LIKE"

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
    const val NOTIFICATION_CHANNEL_NAME = "Like Spotify Listener"
    const val NOTIFICATION_ID = 11001
}
