import 'package:app_links/app_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/music/active_music_service_repository.dart';
import '../../data/music/music_service_factory.dart';
import '../../data/platform/android_platform_service_repository.dart';
import '../../data/settings/shared_prefs_settings_repository.dart';
import '../../data/ytmusic/ytmusic_music_service_repository.dart';
import '../../domain/repositories/device_sign_in_repository.dart';
import '../../domain/repositories/music_routing_repository.dart';
import '../../domain/repositories/music_service_repository.dart';
import '../../domain/repositories/platform_service_repository.dart';
import '../../domain/repositories/settings_repository.dart';
import '../../domain/services/signal_pattern_matcher.dart';
import 'app_controller.dart';
import 'app_state.dart';
import 'ytmusic_sign_in_controller.dart';

const _redirectUri = String.fromEnvironment(
  'SPOTIFY_REDIRECT_URI',
  defaultValue: 'likespotify://auth-callback',
);
const _spotifyClientId = String.fromEnvironment('SPOTIFY_CLIENT_ID');
const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

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
    config: const MusicServiceConfig(
      spotifyClientId: _spotifyClientId,
      spotifyRedirectUri: _redirectUri,
      supabaseUrl: _supabaseUrl,
      supabaseAnonKey: _supabaseAnonKey,
    ),
    settingsRepository: ref.read(settingsRepositoryProvider),
    platformServiceRepository: ref.read(platformServiceRepositoryProvider),
    youTubeMusic: ref.read(youTubeMusicRepositoryProvider),
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
    supabaseUrl: _supabaseUrl,
    supabaseAnonKey: _supabaseAnonKey,
  );
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
