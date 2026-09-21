import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../../domain/entities/music_provider.dart';
import '../../domain/repositories/like_count_repository.dart';
import '../../domain/repositories/music_service_repository.dart';
import '../../domain/repositories/platform_service_repository.dart';
import '../../domain/repositories/settings_repository.dart';
import '../../domain/services/like_counter_user_id.dart';
import '../google/google_oauth_client.dart';
import '../likes/google_sheets_like_count_repository.dart';
import '../likes/like_counter_account.dart';
import '../likes/like_counter_store.dart';
import '../spotify/spotify_client.dart';
import '../spotify/spotify_music_service_repository.dart';
import '../spotify/spotify_token_store.dart';
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
  required LikeCounterStore likeCounterStore,
  required LikeCounterAccount likeCounterAccount,
}) {
  // GoogleSheetsLikeCountRepository asks for the user id at increment time,
  // so the repository it asks need not exist yet when it is built.
  late final SpotifyMusicServiceRepository spotify;

  // Always the sheet-backed repository: the counter can be set up while the
  // app runs, and with nothing set up it counts locally anyway.
  final LikeCountRepository likeCountRepository =
      GoogleSheetsLikeCountRepository(
    readSpreadsheetId: () async => (await likeCounterStore.read()).spreadsheetId,
    readAccessToken: likeCounterAccount.freshAccessToken,
    // Only Spotify likes go through this repository; YouTube Music likes are
    // counted natively (YouTubeMusicLiker.kt) under the `sub`.
    userIdGetter: () async => likeCounterUserId(
      MusicProvider.spotify,
      spotifyUserId: await spotify.ensureUserId(),
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

/// The shared like counter's Google account. Built separately because the
/// Connected services screen drives its sign-in directly, and the Spotify
/// like path reads its access token.
LikeCounterAccount createLikeCounterAccount({
  required LikeCounterStore store,
  required PlatformServiceRepository platformServiceRepository,
}) {
  return LikeCounterAccount(
    oauthClient: GoogleOAuthClient(http.Client()),
    store: store,
    platformServiceRepository: platformServiceRepository,
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
