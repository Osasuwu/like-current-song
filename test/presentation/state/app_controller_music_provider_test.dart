import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/app_log.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';
import 'package:like_spotify_mobile_app/domain/entities/spotify_auth_state.dart';
import 'package:like_spotify_mobile_app/presentation/state/app_controller.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/app_controller_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppControllerHarness harness;
  late AppController controller;

  setUpAll(registerAppControllerFallbacks);

  /// Builds the controller on [selected] and lets its start-up finish, then
  /// forgets the start-up calls so every `verify` below is about the switch.
  Future<void> startOn(MusicProvider selected) async {
    harness = AppControllerHarness(selected: selected);
    controller = harness.build();
    await pumpEventQueue();
    expect(controller.state.musicProvider, selected);
    clearInteractions(harness.settings);
    clearInteractions(harness.platform);
    clearInteractions(harness.spotify);
    clearInteractions(harness.ytmusic);
  }

  setUp(silenceConnectivityChannel);

  tearDown(() => controller.dispose());

  test('persists the choice and mirrors it to the native listener', () async {
    await startOn(MusicProvider.spotify);

    await controller.selectMusicProvider(MusicProvider.ytmusic);

    verify(() => harness.settings.saveMusicProvider(MusicProvider.ytmusic))
        .called(1);
    verify(() => harness.platform.updateMusicProvider(MusicProvider.ytmusic))
        .called(1);
    expect(controller.state.musicProvider, MusicProvider.ytmusic);
  });

  test('leaves both services signed in', () async {
    await startOn(MusicProvider.spotify);

    await controller.selectMusicProvider(MusicProvider.ytmusic);

    // Switching is not signing out: neither token store may be touched, or
    // the user has to sign in again every time they change their mind.
    verifyNever(() => harness.spotify.disconnect());
    verifyNever(() => harness.ytmusic.disconnect());
    verifyNever(() => harness.platform.clearYouTubeMusicTokens());
  });

  test('switching back leaves both services signed in too', () async {
    await startOn(MusicProvider.ytmusic);

    await controller.selectMusicProvider(MusicProvider.spotify);

    expect(controller.state.musicProvider, MusicProvider.spotify);
    verifyNever(() => harness.spotify.disconnect());
    verifyNever(() => harness.ytmusic.disconnect());
    verifyNever(() => harness.platform.clearYouTubeMusicTokens());
  });

  test('shows the connection state of the service switched to', () async {
    await startOn(MusicProvider.spotify);
    when(() => harness.ytmusic.getAuthState()).thenAnswer(
      (_) async => SpotifyAuthState(
        accessToken: 'token',
        refreshToken: 'refresh',
        expiresAt: DateTime.utc(2030),
        connected: true,
        accountId: 'google-sub',
      ),
    );

    await controller.selectMusicProvider(MusicProvider.ytmusic);

    expect(controller.state.authState.connected, isTrue);
    expect(controller.state.authState.accountId, 'google-sub');
    // Read from the service just chosen, not the one left behind.
    verify(() => harness.ytmusic.getAuthState()).called(1);
    verifyNever(() => harness.spotify.getAuthState());
  });

  test('logs the switch, saying whether the new service is connected',
      () async {
    await startOn(MusicProvider.spotify);

    await controller.selectMusicProvider(MusicProvider.ytmusic);

    final log = verify(() => harness.settings.appendLog(captureAny()))
        .captured
        .single as AppLog;
    expect(log.actionType, 'music_provider');
    expect(log.result, LogResult.success);
    expect(log.message, contains('YouTube Music'));
    expect(log.message, contains('not connected'));
  });

  test('picking the service already selected does nothing', () async {
    await startOn(MusicProvider.spotify);

    await controller.selectMusicProvider(MusicProvider.spotify);

    verifyNever(() => harness.settings.saveMusicProvider(any()));
    verifyNever(() => harness.platform.updateMusicProvider(any()));
    verifyNever(() => harness.settings.appendLog(any()));
  });

  test('a failed save surfaces as an error and keeps the old service',
      () async {
    await startOn(MusicProvider.spotify);
    when(() => harness.settings.saveMusicProvider(any()))
        .thenThrow(Exception('disk full'));

    await controller.selectMusicProvider(MusicProvider.ytmusic);

    expect(controller.state.musicProvider, MusicProvider.spotify);
    expect(controller.state.lastError, contains('disk full'));
    verifyNever(() => harness.platform.updateMusicProvider(any()));
    verifyNever(() => harness.spotify.disconnect());
    verifyNever(() => harness.ytmusic.disconnect());
  });
}
