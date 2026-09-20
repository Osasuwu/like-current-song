import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:like_spotify_mobile_app/core/app_constants.dart';
import 'package:like_spotify_mobile_app/domain/entities/app_log.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';
import 'package:like_spotify_mobile_app/domain/entities/pending_like.dart';
import 'package:like_spotify_mobile_app/domain/entities/rule_config.dart';
import 'package:like_spotify_mobile_app/domain/entities/spotify_auth_state.dart';
import 'package:like_spotify_mobile_app/domain/entities/trigger_config.dart';
import 'package:like_spotify_mobile_app/presentation/state/app_controller.dart';
import 'package:like_spotify_mobile_app/presentation/state/app_providers.dart';
import 'package:mocktail/mocktail.dart';

import 'mocks.dart';

class MockAppLinks extends Mock implements AppLinks {}

const _triggerConfig = TriggerConfig(
  pattern: AppConstants.defaultPattern,
  windowMs: AppConstants.defaultWindowMs,
  debounceMs: AppConstants.defaultDebounceMs,
  feedbackVolume: AppConstants.defaultFeedbackVolume,
);

/// Hosts [screen] over a real [AppController] fed by stubbed repositories, so
/// the screen sees the state a given service selection actually produces.
///
/// [pendingLikes] is how many likes the offline queue holds; those entries are
/// always Spotify's, which is the only service that queues.
Widget hostScreen(
  Widget screen, {
  MusicProvider provider = MusicProvider.spotify,
  int pendingLikes = 0,
}) {
  registerFallbackValue(MusicProvider.spotify);
  registerFallbackValue(_triggerConfig);
  registerFallbackValue(RuleConfig.defaults());

  final settings = MockSettingsRepository();
  final platform = MockPlatformServiceRepository();
  final music = MockMusicServiceRepository();
  final appLinks = MockAppLinks();

  when(() => settings.loadTriggerConfig())
      .thenAnswer((_) async => _triggerConfig);
  when(() => settings.loadMusicProvider()).thenAnswer((_) async => provider);
  when(() => settings.loadRuleConfig())
      .thenAnswer((_) async => RuleConfig.defaults());
  when(() => settings.loadLogs()).thenAnswer((_) async => <AppLog>[]);
  when(() => settings.loadPendingLikes()).thenAnswer(
    (_) async => List<PendingLike>.generate(
      pendingLikes,
      (i) => PendingLike(
        trackId: 'track-$i',
        trackName: 'Track $i',
        artistIds: const <String>[],
        artistNames: const <String>[],
        queuedAt: DateTime.utc(2026),
      ),
    ),
  );
  when(() => platform.isServiceEnabled()).thenAnswer((_) async => false);
  when(() => platform.isIgnoringBatteryOptimizations())
      .thenAnswer((_) async => true);
  when(() => platform.isNotificationListenerEnabled())
      .thenAnswer((_) async => true);
  when(() => platform.isMiuiDevice()).thenAnswer((_) async => false);
  when(() => platform.isMusicAppInstalled(any())).thenAnswer((_) async => true);
  when(() => platform.updateMusicProvider(any())).thenAnswer((_) async {});
  when(() => platform.updateTriggerConfig(any())).thenAnswer((_) async {});
  when(() => platform.updateRuleConfig(any())).thenAnswer((_) async {});
  when(() => platform.syncSupabaseConfig(
        supabaseUrl: any(named: 'supabaseUrl'),
        supabaseAnonKey: any(named: 'supabaseAnonKey'),
      )).thenAnswer((_) async {});
  when(platform.events)
      .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
  when(() => music.getAuthState())
      .thenAnswer((_) async => const SpotifyAuthState.disconnected());
  when(() => appLinks.uriLinkStream)
      .thenAnswer((_) => const Stream<Uri>.empty());

  return ProviderScope(
    overrides: <Override>[
      appControllerProvider.overrideWith(
        (ref) => AppController(
          settingsRepository: settings,
          platformServiceRepository: platform,
          musicServiceRepository: music,
          appLinks: appLinks,
        ),
      ),
    ],
    child: MaterialApp(home: screen),
  );
}
