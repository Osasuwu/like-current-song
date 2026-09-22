import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/app_log.dart';
import 'package:like_spotify_mobile_app/domain/entities/like_destination.dart';
import 'package:like_spotify_mobile_app/domain/entities/like_result.dart';
import 'package:like_spotify_mobile_app/domain/entities/rule_config.dart';
import 'package:like_spotify_mobile_app/presentation/state/app_controller.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/app_controller_harness.dart';

/// What the Logs screen says about a like that went somewhere other than
/// liked songs, and what the settings screen refuses to save.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppControllerHarness harness;
  late AppController controller;

  setUpAll(registerAppControllerFallbacks);
  setUp(silenceConnectivityChannel);
  tearDown(() => controller.dispose());

  Future<void> start() async {
    harness = AppControllerHarness();
    controller = harness.build();
    await pumpEventQueue();
    clearInteractions(harness.settings);
    clearInteractions(harness.platform);
  }

  List<AppLog> loggedLines() =>
      verify(() => harness.settings.appendLog(captureAny()))
          .captured
          .cast<AppLog>();

  LikeResult likeResult({
    bool likedNatively = true,
    bool addedToLikePlaylist = false,
    String? partialFailureMessage,
  }) =>
      LikeResult(
        trackId: 'track-123',
        trackName: 'Test Song',
        trackLiked: true,
        likedNatively: likedNatively,
        addedToLikePlaylist: addedToLikePlaylist,
        partialFailureMessage: partialFailureMessage,
      );

  group('like logging', () {
    test('a like that reached the playlist says so', () async {
      await start();
      when(() => harness.spotify.likeCurrentTrack()).thenAnswer(
        (_) async => likeResult(likedNatively: false, addedToLikePlaylist: true),
      );

      await controller.likeCurrentTrackNow();

      final playlistLines = loggedLines()
          .where((log) => log.actionType == 'like_playlist_add')
          .toList();
      expect(playlistLines, hasLength(1));
      expect(playlistLines.single.result, LogResult.success);
      expect(playlistLines.single.message, 'Added to like playlist');
    });

    test('a half-failed both like still counts, and names the failed leg',
        () async {
      await start();
      when(() => harness.spotify.likeCurrentTrack()).thenAnswer(
        (_) async => likeResult(
          likedNatively: false,
          addedToLikePlaylist: true,
          partialFailureMessage:
              'Liked songs failed, so the like only reached "Trigger likes": '
              'Exception: nope',
        ),
      );

      await controller.likeCurrentTrackNow();

      final lines = loggedLines();
      // The like itself still counted.
      final likeLine =
          lines.firstWhere((log) => log.actionType == 'like_track');
      expect(likeLine.result, LogResult.success);
      // …and the leg that did not go through gets its own failure line.
      final failure = lines.lastWhere(
        (log) => log.actionType == 'like_playlist_add',
      );
      expect(failure.result, LogResult.failure);
      expect(failure.message, contains('Liked songs failed'));
      expect(controller.state.lastLikeResult?.trackLiked, isTrue);
    });

    test('an ordinary like logs no playlist line', () async {
      await start();
      when(() => harness.spotify.likeCurrentTrack())
          .thenAnswer((_) async => likeResult());

      await controller.likeCurrentTrackNow();

      expect(
        loggedLines().where((log) => log.actionType == 'like_playlist_add'),
        isEmpty,
      );
    });
  });

  group('saveRuleConfig', () {
    test('refuses a playlist destination with no playlist name', () async {
      await start();

      await controller.saveRuleConfig(
        RuleConfig.defaults().copyWith(
          likeDestination: LikeDestination.playlist,
          likePlaylistName: '   ',
        ),
      );

      verifyNever(() => harness.settings.saveRuleConfig(any()));
      verifyNever(() => harness.platform.updateRuleConfig(any()));
      expect(controller.state.lastError, contains('Like playlist name'));
      expect(controller.state.ruleConfig.likeDestination, LikeDestination.native);
    });

    test('saves a named playlist destination, trimmed', () async {
      await start();
      when(() => harness.settings.saveRuleConfig(any()))
          .thenAnswer((_) async {});

      await controller.saveRuleConfig(
        RuleConfig.defaults().copyWith(
          likeDestination: LikeDestination.both,
          likePlaylistName: '  Trigger likes  ',
        ),
      );

      final saved = verify(() => harness.settings.saveRuleConfig(captureAny()))
          .captured
          .single as RuleConfig;
      expect(saved.likeDestination, LikeDestination.both);
      expect(saved.likePlaylistName, 'Trigger likes');
      // The native side has to learn about it too, or a detached like would
      // still go to liked songs only.
      verify(() => harness.platform.updateRuleConfig(any())).called(1);
      expect(controller.state.ruleConfig.likePlaylistName, 'Trigger likes');
    });
  });
}
