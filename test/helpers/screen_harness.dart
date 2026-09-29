import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:like_spotify_mobile_app/domain/entities/app_log.dart';
import 'package:like_spotify_mobile_app/domain/entities/like_counter_config.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';
import 'package:like_spotify_mobile_app/domain/entities/pending_like.dart';

import 'app_controller_harness.dart';

/// Hosts [screen] over a real `AppController` fed by an
/// [AppControllerHarness], so the screen sees the state a given service
/// selection actually produces. A shorthand for the common screen-test knobs;
/// a test that needs more builds the harness itself and calls
/// [AppControllerHarness.host].
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
///
/// [logs] is what the log store already holds, newest first, as
/// `SettingsRepository.loadLogs` hands it over.
Widget hostScreen(
  Widget screen, {
  MusicProvider provider = MusicProvider.spotify,
  int pendingLikes = 0,
  String spotifyClientId = 'test-client-id',
  LikeCounterConfig counter = LikeCounterConfig.empty,
  bool notificationAccess = true,
  bool serviceEnabled = false,
  List<AppLog> logs = const <AppLog>[],
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
  registerAppControllerFallbacks();

  final harness = AppControllerHarness(selected: provider)
    ..counterConfig = counter
    ..notificationAccess = notificationAccess
    ..serviceEnabled = serviceEnabled
    ..logs = logs
    ..pendingLikes = List<PendingLike>.generate(
      pendingLikes,
      (i) => PendingLike(
        trackId: 'track-$i',
        trackName: 'Track $i',
        artistIds: const <String>[],
        artistNames: const <String>[],
        queuedAt: DateTime.utc(2026),
      ),
    );
  return harness.host(screen);
}
