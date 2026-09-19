import 'package:app_links/app_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/music/music_service_factory.dart';
import '../../data/platform/android_platform_service_repository.dart';
import '../../data/settings/shared_prefs_settings_repository.dart';
import '../../domain/repositories/music_service_repository.dart';
import '../../domain/repositories/platform_service_repository.dart';
import '../../domain/repositories/settings_repository.dart';
import '../../domain/services/signal_pattern_matcher.dart';
import 'app_controller.dart';
import 'app_state.dart';

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

final musicServiceRepositoryProvider = Provider<MusicServiceRepository>(
  (ref) => createMusicServiceRepository(
    config: const MusicServiceConfig(
      spotifyClientId: _spotifyClientId,
      spotifyRedirectUri: _redirectUri,
      supabaseUrl: _supabaseUrl,
      supabaseAnonKey: _supabaseAnonKey,
    ),
    settingsRepository: ref.read(settingsRepositoryProvider),
    platformServiceRepository: ref.read(platformServiceRepositoryProvider),
  ),
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
    appLinks: ref.read(appLinksProvider),
    supabaseUrl: _supabaseUrl,
    supabaseAnonKey: _supabaseAnonKey,
  );
});
