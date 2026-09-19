import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../../domain/entities/music_provider.dart';
import '../../domain/repositories/like_count_repository.dart';
import '../../domain/repositories/music_service_repository.dart';
import '../../domain/repositories/platform_service_repository.dart';
import '../../domain/repositories/settings_repository.dart';
import '../likes/shared_prefs_like_count_repository.dart';
import '../likes/supabase_like_count_repository.dart';
import '../spotify/spotify_client.dart';
import '../spotify/spotify_music_service_repository.dart';
import '../spotify/spotify_token_store.dart';
import '../ytmusic/ytmusic_music_service_repository.dart';
import 'active_music_service_repository.dart';

/// Build-time credentials for the music services and the shared counter.
class MusicServiceConfig {
  const MusicServiceConfig({
    required this.spotifyClientId,
    required this.spotifyRedirectUri,
    this.supabaseUrl = '',
    this.supabaseAnonKey = '',
  });

  final String spotifyClientId;
  final String spotifyRedirectUri;
  final String supabaseUrl;
  final String supabaseAnonKey;

  bool get hasSupabase => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}

/// Wires one repository per [MusicProvider] behind an
/// [ActiveMusicServiceRepository] that follows the Settings selection.
///
/// This is the only place that knows the concrete music-service classes; a
/// new service is added by registering its repository here.
MusicServiceRepository createMusicServiceRepository({
  required MusicServiceConfig config,
  required SettingsRepository settingsRepository,
  required PlatformServiceRepository platformServiceRepository,
}) {
  // SupabaseLikeCountRepository reads cachedUserId lazily at increment time,
  // so null on first call just falls back to local.
  late final SpotifyMusicServiceRepository spotify;

  final LikeCountRepository likeCountRepository = config.hasSupabase
      ? SupabaseLikeCountRepository(
          supabaseUrl: config.supabaseUrl,
          supabaseAnonKey: config.supabaseAnonKey,
          userIdGetter: () => spotify.cachedUserId,
        )
      : SharedPrefsLikeCountRepository();

  spotify = SpotifyMusicServiceRepository(
    spotifyClient: SpotifyClient(http.Client()),
    tokenStore: SpotifyTokenStore(const FlutterSecureStorage()),
    platformServiceRepository: platformServiceRepository,
    likeCountRepository: likeCountRepository,
    settingsRepository: settingsRepository,
    clientId: config.spotifyClientId,
    redirectUri: config.spotifyRedirectUri,
  );

  return ActiveMusicServiceRepository(
    settingsRepository: settingsRepository,
    repositories: <MusicProvider, MusicServiceRepository>{
      MusicProvider.spotify: spotify,
      MusicProvider.ytmusic: YouTubeMusicServiceRepository(
        platformServiceRepository: platformServiceRepository,
      ),
    },
  );
}
