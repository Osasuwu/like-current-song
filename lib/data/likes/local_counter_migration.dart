import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'native_like_count_repository.dart';
import 'shared_prefs_like_count_repository.dart';

/// Moves the like counters Flutter used to keep to their side into the native
/// store both halves of the app now share.
///
/// Until #197 a like tapped in the app and a like fired by a media button
/// landed in different SharedPreferences files, so anyone who used both had
/// two partial counts and rules that never fired. Pointing Dart at the native
/// store fixes new likes; this brings the old ones along, once, on the first
/// launch after the change.
class LocalCounterMigration {
  LocalCounterMigration({
    SharedPrefsLikeCountRepository? source,
    NativeLikeCountRepository destination = const NativeLikeCountRepository(),
  })  : _source = source ?? SharedPrefsLikeCountRepository(),
        _destination = destination;

  /// Set on the Dart side once the counters are safely across. The `_v1`
  /// suffix leaves room for a later migration to run on its own flag.
  static const migratedFlagKey = 'local_counters_migrated_v1';

  final SharedPrefsLikeCountRepository _source;
  final NativeLikeCountRepository _destination;

  /// Runs the migration if it has not run before.
  ///
  /// Nothing is thrown away before the native side has taken the counters,
  /// and the flag is only set once it has; a merge that threw leaves both
  /// sides exactly as they were, so the next launch simply tries again. The
  /// merge itself takes the larger of the two values per key, which is what
  /// makes that retry harmless.
  Future<void> run() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(migratedFlagKey) ?? false) return;

    final tracks = await _source.loadAllTrackLikeCounts();
    final artists = await _source.loadAllArtistLikeCounts();
    final lastLikedAt = await _source.loadAllLastLikedAt();

    // The common case by far — a fresh install, or one that only ever liked
    // through the media button. Nothing to hand over, so nothing to ask the
    // native side about either.
    if (tracks.isEmpty && artists.isEmpty && lastLikedAt.isEmpty) {
      await prefs.setBool(migratedFlagKey, true);
      return;
    }

    // The reply tells us whether the native side had to write anything, which
    // is not the same question as whether the counters are across: it comes
    // back false when the native store already held a value at least as large
    // for every key handed over, and that is as finished as a write. Only a
    // throw means they did not make it.
    try {
      await _destination.mergeLocalCounters(
        tracks: tracks,
        artists: artists,
        lastLikedAt: lastLikedAt.map(
          (trackId, at) => MapEntry(trackId, at.toUtc().millisecondsSinceEpoch),
        ),
      );
    } catch (error) {
      debugPrint('Local counter merge failed, will retry next launch: $error');
      return;
    }

    await _source.clearAll();
    await prefs.setBool(migratedFlagKey, true);
  }
}
