import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:like_spotify_mobile_app/core/app_constants.dart';
import 'package:like_spotify_mobile_app/domain/entities/app_log.dart';
import 'package:like_spotify_mobile_app/domain/entities/like_counter_config.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_routing.dart';
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
///
/// [spotifyClientId] is what the credentials store already holds; the default
/// stands for an app that has been set up, and `''` for one that has not.
///
/// [notificationAccess] is the grant the trigger runs on — the default stands
/// for a phone where it was given, `false` for one where it was not and the
/// trigger therefore cannot fire at all.
Widget hostScreen(
  Widget screen, {
  MusicProvider provider = MusicProvider.spotify,
  int pendingLikes = 0,
  String spotifyClientId = 'test-client-id',
  LikeCounterConfig counter = LikeCounterConfig.empty,
  bool notificationAccess = true,
  bool serviceEnabled = false,
}) {
  FlutterSecureStorage.setMockInitialValues(<String, String>{
    if (spotifyClientId.isNotEmpty) 'spotify_client_id': spotifyClientId,
    if (counter.spreadsheetId.isNotEmpty)
      'counter_spreadsheet_id': counter.spreadsheetId,
    if (counter.clientId.isNotEmpty)
      'counter_google_client_id': counter.clientId,
    if (counter.clientSecret.isNotEmpty)
      'counter_google_client_secret': counter.clientSecret,
    if (counter.accessToken.isNotEmpty)
      'counter_google_access': counter.accessToken,
    if (counter.refreshToken.isNotEmpty)
      'counter_google_refresh': counter.refreshToken,
    if (counter.expiresAt != null)
      'counter_google_expiry_epoch_ms':
          counter.expiresAt!.millisecondsSinceEpoch.toString(),
  });

  registerFallbackValue(MusicProvider.spotify);
  registerFallbackValue(MusicRoutingMode.defaultMode);
  registerFallbackValue(_triggerConfig);
  registerFallbackValue(RuleConfig.defaults());

  final settings = MockSettingsRepository();
  final platform = MockPlatformServiceRepository();
  final music = MockMusicServiceRepository();
  final routing = MockMusicRoutingRepository();
  final appLinks = MockAppLinks();

  when(() => settings.loadTriggerConfig())
      .thenAnswer((_) async => _triggerConfig);
  when(() => settings.loadMusicProvider()).thenAnswer((_) async => provider);
  // Automatic routing is opt-in; these screens are about the picked service.
  when(() => settings.loadMusicRoutingMode())
      .thenAnswer((_) async => MusicRoutingMode.picker);
  when(() => settings.saveMusicRoutingMode(any())).thenAnswer((_) async {});
  when(() => routing.connectedProviders())
      .thenAnswer((_) async => <MusicProvider>{provider});
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
  when(() => platform.isServiceEnabled()).thenAnswer((_) async => serviceEnabled);
  when(() => platform.isIgnoringBatteryOptimizations())
      .thenAnswer((_) async => true);
  when(() => platform.isNotificationListenerEnabled())
      .thenAnswer((_) async => notificationAccess);
  when(() => platform.openNotificationListenerSettings())
      .thenAnswer((_) async {});
  when(() => platform.isMiuiDevice()).thenAnswer((_) async => false);
  when(() => platform.isMusicAppInstalled(any())).thenAnswer((_) async => true);
  when(() => platform.updateMusicProvider(any())).thenAnswer((_) async {});
  when(() => platform.updateMusicRoutingMode(any())).thenAnswer((_) async {});
  when(() => platform.readMusicSessions())
      .thenAnswer((_) async => const MusicSessionSnapshot());
  when(() => platform.updateTriggerConfig(any())).thenAnswer((_) async {});
  when(() => platform.updateRuleConfig(any())).thenAnswer((_) async {});
  when(() => platform.syncLikeCounterConfig(
        spreadsheetId: any(named: 'spreadsheetId'),
        clientId: any(named: 'clientId'),
        clientSecret: any(named: 'clientSecret'),
        accessToken: any(named: 'accessToken'),
        refreshToken: any(named: 'refreshToken'),
        expiresAtEpochMs: any(named: 'expiresAtEpochMs'),
      )).thenAnswer((_) async {});
  when(() => platform.drainBackgroundLogs())
      .thenAnswer((_) async => <AppLog>[]);
  when(platform.events)
      .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
  when(() => music.getAuthState())
      .thenAnswer((_) async => const SpotifyAuthState.disconnected());
  when(() => appLinks.uriLinkStream)
      .thenAnswer((_) => const Stream<Uri>.empty());

  return ProviderScope(
    overrides: <Override>[
      platformServiceRepositoryProvider.overrideWithValue(platform),
      appControllerProvider.overrideWith(
        (ref) => AppController(
          settingsRepository: settings,
          platformServiceRepository: platform,
          musicServiceRepository: music,
          musicRoutingRepository: routing,
          appLinks: appLinks,
          readLikeCounterConfig: () async => counter,
        ),
      ),
    ],
    child: MaterialApp(home: screen),
  );
}
