import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/data/likes/local_counter_migration.dart';
import 'package:like_spotify_mobile_app/data/likes/native_like_count_repository.dart';
import 'package:like_spotify_mobile_app/data/likes/shared_prefs_like_count_repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockNativeLikeCountRepository extends Mock
    implements NativeLikeCountRepository {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockNativeLikeCountRepository native;
  late SharedPrefsLikeCountRepository source;

  /// The three maps as the old Dart-side store held them.
  Map<String, Object> storedCounters() => <String, Object>{
        'track_like_counts': jsonEncode(<String, int>{'track-1': 2}),
        'artist_like_counts': jsonEncode(<String, int>{'artist-1': 4}),
        'track_last_liked_at':
            jsonEncode(<String, int>{'track-1': 1700000000000}),
      };

  void givenPrefs(Map<String, Object> values) {
    SharedPreferences.setMockInitialValues(values);
    source = SharedPrefsLikeCountRepository();
  }

  Future<void> runMigration() =>
      LocalCounterMigration(source: source, destination: native).run();

  Future<bool?> readFlag() async =>
      (await SharedPreferences.getInstance())
          .getBool(LocalCounterMigration.migratedFlagKey);

  setUp(() {
    native = MockNativeLikeCountRepository();
    givenPrefs(<String, Object>{});
  });

  void stubMerge(Future<bool> Function() answer) {
    when(() => native.mergeLocalCounters(
          tracks: any(named: 'tracks'),
          artists: any(named: 'artists'),
          lastLikedAt: any(named: 'lastLikedAt'),
        )).thenAnswer((_) => answer());
  }

  test('does nothing at all once the flag is set', () async {
    givenPrefs(<String, Object>{
      ...storedCounters(),
      LocalCounterMigration.migratedFlagKey: true,
    });

    await runMigration();

    verifyZeroInteractions(native);
    // The old maps are left alone too: a second run must not be able to
    // delete counters the first run already handed over.
    expect(await source.getTrackLikeCount('track-1'), 2);
  });

  test('sets the flag without a channel call when there is nothing to move',
      () async {
    await runMigration();

    verifyZeroInteractions(native);
    expect(await readFlag(), isTrue);
  });

  test('hands all three maps over, then clears them and sets the flag',
      () async {
    givenPrefs(storedCounters());
    stubMerge(() async => true);

    await runMigration();

    final call = verify(() => native.mergeLocalCounters(
          tracks: captureAny(named: 'tracks'),
          artists: captureAny(named: 'artists'),
          lastLikedAt: captureAny(named: 'lastLikedAt'),
        )).captured;
    expect(call[0], <String, int>{'track-1': 2});
    expect(call[1], <String, int>{'artist-1': 4});
    expect(call[2], <String, int>{'track-1': 1700000000000});

    expect(await source.getTrackLikeCount('track-1'), 0);
    expect(await source.getArtistLikeCount('artist-1'), 0);
    expect(await source.getLastLikedAt('track-1'), isNull);
    expect(await readFlag(), isTrue);
  });

  test('finishes even when the native side had already folded the counters in',
      () async {
    // False is what the native side answers when an earlier call already did
    // the folding — a run that merged and then died before clearing, say.
    // Treating that as a failure would leave the old maps behind and retry the
    // migration on every launch, forever.
    givenPrefs(storedCounters());
    stubMerge(() async => false);

    await runMigration();

    expect(await source.getTrackLikeCount('track-1'), 0);
    expect(await source.getArtistLikeCount('artist-1'), 0);
    expect(await readFlag(), isTrue);
  });

  test('leaves everything alone when the merge throws', () async {
    givenPrefs(storedCounters());
    stubMerge(() async => throw Exception('channel is down'));

    await runMigration();

    expect(await source.getTrackLikeCount('track-1'), 2);
    expect(await source.getArtistLikeCount('artist-1'), 4);
    expect(await readFlag(), isNull);
  });

  test('retries after a failure and finishes on the second run', () async {
    givenPrefs(storedCounters());
    var attempts = 0;
    stubMerge(() async {
      attempts++;
      if (attempts == 1) throw Exception('channel is down');
      return true;
    });

    await runMigration();
    await runMigration();

    expect(attempts, 2);
    expect(await source.getTrackLikeCount('track-1'), 0);
    expect(await readFlag(), isTrue);
  });
}
