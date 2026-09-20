import 'package:app_links/app_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../data/likes/supabase_config_store.dart';
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
import '../../domain/services/signal_pattern_matcher.dart';
import 'app_controller.dart';
import 'app_state.dart';
import 'service_credentials_controller.dart';
import 'ytmusic_sign_in_controller.dart';

/// The Spotify client ID and the counter config live here, written by
/// *Connected services* and read by the repositories at call time. One
/// instance each, so a save is visible to the next read.
final spotifyTokenStoreProvider = Provider<SpotifyTokenStore>(
  (ref) => SpotifyTokenStore(const FlutterSecureStorage()),
);

final supabaseConfigStoreProvider = Provider<SupabaseConfigStore>(
  (ref) => SupabaseConfigStore(const FlutterSecureStorage()),
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

/// The one instance behind both seams below: it is a music service (the like
/// path) and the routing rule (which service that is) at once.
final activeMusicServiceRepositoryProvider =
    Provider<ActiveMusicServiceRepository>(
  (ref) => createMusicServiceRepository(
    settingsRepository: ref.read(settingsRepositoryProvider),
    platformServiceRepository: ref.read(platformServiceRepositoryProvider),
    youTubeMusic: ref.read(youTubeMusicRepositoryProvider),
    spotifyTokenStore: ref.read(spotifyTokenStoreProvider),
    supabaseConfigStore: ref.read(supabaseConfigStoreProvider),
  ),
);

final musicServiceRepositoryProvider = Provider<MusicServiceRepository>(
  (ref) => ref.read(activeMusicServiceRepositoryProvider),
);

final musicRoutingRepositoryProvider = Provider<MusicRoutingRepository>(
  (ref) => ref.read(activeMusicServiceRepositoryProvider),
);

final appLinksProvider = Provider<AppLinks>((ref) => AppLinks());

final signalPatternMatcherProvider = Provider<SignalPatternMatcher>(
  (ref) => SignalPatternMatcher(),
);

final appControllerProvider =
    StateNotifierProvider<AppController, AppState>((ref) {
  return AppController(
    settingsRepository: ref.read(settingsRepositoryProvider),
    platformServiceRepository: ref.read(platformServiceRepositoryProvider),
    musicServiceRepository: ref.read(musicServiceRepositoryProvider),
    musicRoutingRepository: ref.read(musicRoutingRepositoryProvider),
    appLinks: ref.read(appLinksProvider),
    readSupabaseConfig: ref.read(supabaseConfigStoreProvider).read,
  );
});

/// The credentials typed on *Connected services*. Not auto-disposed: the
/// screen's Connect button reads it too, and a saved client ID should not be
/// re-read from storage on every rebuild.
final serviceCredentialsControllerProvider = StateNotifierProvider<
    ServiceCredentialsController, ServiceCredentialsState>((ref) {
  final controller = ServiceCredentialsController(
    spotifyTokenStore: ref.read(spotifyTokenStoreProvider),
    supabaseConfigStore: ref.read(supabaseConfigStoreProvider),
    onSupabaseConfigChanged: (config) =>
        ref.read(platformServiceRepositoryProvider).syncSupabaseConfig(
              supabaseUrl: config.url,
              supabaseAnonKey: config.anonKey,
            ),
  );
  controller.load();
  return controller;
});

final youTubeMusicSignInControllerProvider = StateNotifierProvider.autoDispose<
    YouTubeMusicSignInController, YouTubeMusicSignInState>((ref) {
  final controller = YouTubeMusicSignInController(
    signInRepository: ref.read(deviceSignInRepositoryProvider),
    onSignedIn: () =>
        ref.read(appControllerProvider.notifier).onMusicServiceSignedIn(),
  );
  controller.load();
  return controller;
});
