import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/core/app_constants.dart';
import 'package:like_spotify_mobile_app/data/likes/native_like_count_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppConstants.serviceMethodChannel);
  const repo = NativeLikeCountRepository();

  /// Every call the repository made, in order.
  final calls = <MethodCall>[];

  /// Answers the channel with [reply], and records what was asked.
  void answer(Object? Function(MethodCall call) reply) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  }

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('counts', () {
    test('increments a track under the track kind', () async {
      answer((_) => 4);

      expect(await repo.incrementTrackLikeCount('track-1'), 4);
      expect(calls.single.method, 'incrementLocalCount');
      expect(calls.single.arguments, <String, dynamic>{
        'kind': 'track',
        'id': 'track-1',
      });
    });

    test('increments an artist under the artist kind', () async {
      answer((_) => 7);

      expect(await repo.incrementArtistLikeCount('artist-1'), 7);
      expect(calls.single.method, 'incrementLocalCount');
      expect(calls.single.arguments, <String, dynamic>{
        'kind': 'artist',
        'id': 'artist-1',
      });
    });

    test('reads a track count', () async {
      answer((_) => 2);

      expect(await repo.getTrackLikeCount('track-1'), 2);
      expect(calls.single.method, 'getLocalCount');
      expect(calls.single.arguments, <String, dynamic>{
        'kind': 'track',
        'id': 'track-1',
      });
    });

    test('reads an artist count', () async {
      answer((_) => 9);

      expect(await repo.getArtistLikeCount('artist-9'), 9);
      expect(calls.single.arguments, <String, dynamic>{
        'kind': 'artist',
        'id': 'artist-9',
      });
    });

    test('a count the native side has no answer for is zero', () async {
      answer((_) => null);

      expect(await repo.getTrackLikeCount('never-liked'), 0);
      expect(await repo.incrementArtistLikeCount('artist-1'), 0);
    });
  });

  group('loading whole maps', () {
    test('converts a loosely typed reply into a string-to-int map', () async {
      answer((_) => <Object?, Object?>{'track-1': 3, 'track-2': 1});

      expect(await repo.loadAllTrackLikeCounts(), <String, int>{
        'track-1': 3,
        'track-2': 1,
      });
      expect(calls.single.method, 'loadLocalCounts');
      expect(calls.single.arguments, <String, dynamic>{'kind': 'track'});
    });

    test('asks for the artist map under the artist kind', () async {
      answer((_) => <Object?, Object?>{'artist-1': 5});

      expect(await repo.loadAllArtistLikeCounts(), <String, int>{'artist-1': 5});
      expect(calls.single.arguments, <String, dynamic>{'kind': 'artist'});
    });

    test('drops entries that are not a string keyed count', () async {
      answer((_) => <Object?, Object?>{
            'track-1': 3,
            'track-2': 'not a number',
            7: 4,
          });

      expect(await repo.loadAllTrackLikeCounts(), <String, int>{'track-1': 3});
    });

    test('no map at all is an empty map', () async {
      answer((_) => null);

      expect(await repo.loadAllTrackLikeCounts(), isEmpty);
    });
  });

  group('cooldown stamps', () {
    test('reads a stamp as a UTC time', () async {
      answer((_) => 1700000000000);

      final at = await repo.getLastLikedAt('track-1');

      expect(at, DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true));
      expect(at!.isUtc, isTrue);
      expect(calls.single.method, 'getLastLikedAt');
      expect(calls.single.arguments, <String, dynamic>{'id': 'track-1'});
    });

    test('a track never liked has no stamp', () async {
      answer((_) => null);

      expect(await repo.getLastLikedAt('track-1'), isNull);
    });

    test('records a stamp as UTC epoch millis', () async {
      answer((_) => null);
      final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);

      await repo.recordLikedAt('track-1', at);

      expect(calls.single.method, 'recordLikedAt');
      expect(calls.single.arguments, <String, dynamic>{
        'id': 'track-1',
        'atEpochMillis': 1700000000000,
      });
    });
  });

  group('mergeLocalCounters', () {
    test('sends all three maps under their own keys', () async {
      answer((_) => true);

      final merged = await repo.mergeLocalCounters(
        tracks: <String, int>{'track-1': 2},
        artists: <String, int>{'artist-1': 5},
        lastLikedAt: <String, int>{'track-1': 1700000000000},
      );

      expect(merged, isTrue);
      expect(calls.single.method, 'mergeLocalCounters');
      expect(calls.single.arguments, <String, dynamic>{
        'tracks': <String, int>{'track-1': 2},
        'artists': <String, int>{'artist-1': 5},
        'lastLikedAt': <String, int>{'track-1': 1700000000000},
      });
    });

    test('a reply that is not a yes counts as a refusal', () async {
      answer((_) => null);

      expect(
        await repo.mergeLocalCounters(
          tracks: const <String, int>{},
          artists: const <String, int>{},
          lastLikedAt: const <String, int>{},
        ),
        isFalse,
      );
    });
  });
}
