import 'package:app_links/app_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../data/likes/counter_spreadsheet_creator.dart';
import '../../data/likes/like_counter_account.dart';
import '../../data/likes/like_counter_store.dart';
import '../../data/music/active_music_service_repository.dart';
import '../../data/music/music_service_factory.dart';
import '../../data/platform/android_platform_service_repository.dart';
import '../../data/settings/shared_prefs_settings_repository.dart';
import '../../data/spotify/spotify_token_store.dart';
import '../../data/ytmusic/ytmusic_music_service_repository.dart';
import '../../domain/repositories/device_sign_in_repository.dart';
import '../../domain/repositories/music_routing_repository.dart';
import '../../domain/repositories/music_service_repository.dart';
import '../../domain/repositories/platform_service_repository.dart';
import '../../domain/repositories/settings_repository.dart';
import 'app_controller.dart';
import 'app_state.dart';
import 'service_credentials_controller.dart';
import 'device_sign_in_controller.dart';

/// The Spotify client ID and the counter config live here, written by
/// *Connected services* and read by the repositories at call time. One
/// instance each, so a save is visible to the next read.
final spotifyTokenStoreProvider = Provider<SpotifyTokenStore>(
  (ref) => SpotifyTokenStore(const FlutterSecureStorage()),
);

final likeCounterStoreProvider = Provider<LikeCounterStore>(
  (ref) => LikeCounterStore(const FlutterSecureStorage()),
);

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SharedPrefsSettingsRepository(),
);

final platformServiceRepositoryProvider = Provider<PlatformServiceRepository>(
  (ref) => AndroidPlatformServiceRepository(),
);

final youTubeMusicRepositoryProvider = Provider<YouTubeMusicServiceRepository>(
  (ref) => createYouTubeMusicRepository(
    platformServiceRepository: ref.read(platformServiceRepositoryProvider),
  ),
);

/// YouTube Music's device-code sign-in, driven by Connected services.
final deviceSignInRepositoryProvider = Provider<DeviceSignInRepository>(
  (ref) => ref.read(youTubeMusicRepositoryProvider),
);

/// The shared like counter's own Google account: its own OAuth client, its own
/// token set and the spreadsheets scope, so the counter works whichever music
/// service is picked.
final likeCounterAccountProvider = Provider<LikeCounterAccount>(
  (ref) => createLikeCounterAccount(
    store: ref.read(likeCounterStoreProvider),
    platformServiceRepository: ref.read(platformServiceRepositoryProvider),
  ),
);

/// The one instance behind both seams below: it is a music service (the like
/// path) and the routing rule (which service that is) at once.
final activeMusicServiceRepositoryProvider =
    Provider<ActiveMusicServiceRepository>(
  (ref) => createMusicServiceRepository(
    settingsRepository: ref.read(settingsRepositoryProvider),
    platformServiceRepository: ref.read(platformServiceRepositoryProvider),
    youTubeMusic: ref.read(youTubeMusicRepositoryProvider),
    spotifyTokenStore: ref.read(spotifyTokenStoreProvider),
    likeCounterStore: ref.read(likeCounterStoreProvider),
    likeCounterAccount: ref.read(likeCounterAccountProvider),
  ),
);

final musicServiceRepositoryProvider = Provider<MusicServiceRepository>(
  (ref) => ref.read(activeMusicServiceRepositoryProvider),
);

final musicRoutingRepositoryProvider = Provider<MusicRoutingRepository>(
  (ref) => ref.read(activeMusicServiceRepositoryProvider),
);

final appLinksProvider = Provider<AppLinks>((ref) => AppLinks());

final appControllerProvider =
    StateNotifierProvider<AppController, AppState>((ref) {
  return AppController(
    settingsRepository: ref.read(settingsRepositoryProvider),
    platformServiceRepository: ref.read(platformServiceRepositoryProvider),
    musicServiceRepository: ref.read(musicServiceRepositoryProvider),
    musicRoutingRepository: ref.read(musicRoutingRepositoryProvider),
    appLinks: ref.read(appLinksProvider),
    readLikeCounterConfig: ref.read(likeCounterStoreProvider).read,
  );
});

/// Makes the counter spreadsheet on request, with the counter's own Google
/// sign-in — the same account and the same `spreadsheets` scope the counter
/// already writes with, so creating one asks for no new permission.
final counterSpreadsheetCreatorProvider = Provider<CounterSpreadsheetCreator>(
  (ref) => CounterSpreadsheetCreator(
    readAccessToken: ref.read(likeCounterAccountProvider).freshAccessToken,
  ),
);

/// The credentials typed on *Connected services*. Not auto-disposed: the
/// screen's Connect button reads it too, and a saved client ID should not be
/// re-read from storage on every rebuild.
final serviceCredentialsControllerProvider = StateNotifierProvider<
    ServiceCredentialsController, ServiceCredentialsState>((ref) {
  final controller = ServiceCredentialsController(
    spotifyTokenStore: ref.read(spotifyTokenStoreProvider),
    likeCounterStore: ref.read(likeCounterStoreProvider),
    onLikeCounterConfigChanged: (config) => LikeCounterAccount.pushToNative(
      ref.read(platformServiceRepositoryProvider),
      config,
    ),
    createCounterSheet: () =>
        ref.read(counterSpreadsheetCreatorProvider).create(),
  );
  controller.load();
  return controller;
});

final youTubeMusicSignInControllerProvider = StateNotifierProvider.autoDispose<
    DeviceSignInController, DeviceSignInState>((ref) {
  final controller = DeviceSignInController(
    signInRepository: ref.read(deviceSignInRepositoryProvider),
    onSignedIn: () =>
        ref.read(appControllerProvider.notifier).onMusicServiceSignedIn(),
  );
  controller.load();
  return controller;
});

/// The shared counter's Google sign-in. Separate from YouTube Music's, so both
/// codes can be on screen without one cancelling the other.
final likeCounterSignInControllerProvider = StateNotifierProvider.autoDispose<
    DeviceSignInController, DeviceSignInState>((ref) {
  final controller = DeviceSignInController(
    signInRepository: ref.read(likeCounterAccountProvider),
    // Signing in changes the stored config, which the counter card shows.
    onSignedIn: () =>
        ref.read(serviceCredentialsControllerProvider.notifier).refreshCounter(),
  );
  controller.load();
  return controller;
});
