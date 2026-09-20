import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../../domain/entities/music_provider.dart';
import '../../domain/repositories/like_count_repository.dart';
import '../../domain/repositories/music_service_repository.dart';
import '../../domain/repositories/platform_service_repository.dart';
import '../../domain/repositories/settings_repository.dart';
import '../../domain/services/like_counter_user_id.dart';
import '../likes/supabase_config_store.dart';
import '../likes/supabase_like_count_repository.dart';
import '../spotify/spotify_client.dart';
import '../spotify/spotify_music_service_repository.dart';
import '../spotify/spotify_token_store.dart';
import '../ytmusic/google_oauth_client.dart';
import '../ytmusic/ytmusic_music_service_repository.dart';
import '../ytmusic/ytmusic_token_store.dart';
import 'active_music_service_repository.dart';

/// Wires one repository per [MusicProvider] behind an
/// [ActiveMusicServiceRepository], which owns the routing rule.
///
/// This is the only place that knows the concrete music-service classes; a
/// new service is added by registering its repository here.
///
/// The stores come in rather than being built here, because *Connected
/// services* writes to the same two instances the repositories read from.
ActiveMusicServiceRepository createMusicServiceRepository({
  required SettingsRepository settingsRepository,
  required PlatformServiceRepository platformServiceRepository,
  required MusicServiceRepository youTubeMusic,
  required SpotifyTokenStore spotifyTokenStore,
  required SupabaseConfigStore supabaseConfigStore,
}) {
  // SupabaseLikeCountRepository reads cachedUserId lazily at increment time,
  // so null on first call just falls back to local.
  late final SpotifyMusicServiceRepository spotify;

  // Always the Supabase-backed repository: the project can be configured
  // while the app runs, and with none configured it counts locally anyway.
  final LikeCountRepository likeCountRepository = SupabaseLikeCountRepository(
    readConfig: supabaseConfigStore.read,
    // Only Spotify likes go through this repository; YouTube Music likes are
    // counted natively (YouTubeMusicLiker.kt) under the `sub`.
    userIdGetter: () => likeCounterUserId(
      MusicProvider.spotify,
      spotifyUserId: spotify.cachedUserId,
    ),
  );

  spotify = SpotifyMusicServiceRepository(
    spotifyClient: SpotifyClient(http.Client()),
    tokenStore: spotifyTokenStore,
    platformServiceRepository: platformServiceRepository,
    likeCountRepository: likeCountRepository,
    settingsRepository: settingsRepository,
  );

  return ActiveMusicServiceRepository(
    settingsRepository: settingsRepository,
    platformServiceRepository: platformServiceRepository,
    repositories: <MusicProvider, MusicServiceRepository>{
      MusicProvider.spotify: spotify,
      MusicProvider.ytmusic: youTubeMusic,
    },
  );
}

/// YouTube Music with Google device-flow sign-in. Built separately because the
/// Connected services screen also drives its sign-in directly.
YouTubeMusicServiceRepository createYouTubeMusicRepository({
  required PlatformServiceRepository platformServiceRepository,
}) {
  return YouTubeMusicServiceRepository(
    oauthClient: GoogleOAuthClient(http.Client()),
    tokenStore: YouTubeMusicTokenStore(const FlutterSecureStorage()),
    platformServiceRepository: platformServiceRepository,
  );
}
