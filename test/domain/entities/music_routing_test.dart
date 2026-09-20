import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_routing.dart';

void main() {
  group('MusicRoutingMode', () {
    test('ids match the keys the native side stores', () {
      expect(MusicRoutingMode.picker.id, 'picker');
      expect(MusicRoutingMode.automatic.id, 'automatic');
    });

    test('default is the picker, so automatic stays opt-in', () {
      expect(MusicRoutingMode.defaultMode, MusicRoutingMode.picker);
    });

    test('an install that never wrote the key stays on the picker', () {
      expect(MusicRoutingMode.fromId(null), MusicRoutingMode.picker);
    });

    test('an unknown stored value falls back rather than throwing', () {
      expect(MusicRoutingMode.fromId('whatever'), MusicRoutingMode.picker);
    });

    test('a known value round-trips through its id', () {
      for (final mode in MusicRoutingMode.values) {
        expect(MusicRoutingMode.fromId(mode.id), mode);
      }
    });
  });

  group('MusicRoutingDecision', () {
    test('only the picker reason counts as a non-automatic decision', () {
      for (final reason in MusicRoutingReason.values) {
        final decision = MusicRoutingDecision(
          provider: MusicProvider.spotify,
          reason: reason,
        );
        expect(decision.automatic, reason != MusicRoutingReason.picker);
      }
    });

    test('the log line names the service and the reason', () {
      const decision = MusicRoutingDecision(
        provider: MusicProvider.ytmusic,
        reason: MusicRoutingReason.playingSession,
      );
      expect(
        decision.logLine,
        'Automatic routing -> YouTube Music (playing session)',
      );
    });

    test('two decisions with the same parts are equal', () {
      const a = MusicRoutingDecision(
        provider: MusicProvider.spotify,
        reason: MusicRoutingReason.lastPlaying,
      );
      const b = MusicRoutingDecision(
        provider: MusicProvider.spotify,
        reason: MusicRoutingReason.lastPlaying,
      );
      const other = MusicRoutingDecision(
        provider: MusicProvider.ytmusic,
        reason: MusicRoutingReason.lastPlaying,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(other));
    });
  });

  group('MusicSessionSnapshot.fromChannel', () {
    test('an empty reply is the "automatic cannot answer" case', () {
      final snapshot = MusicSessionSnapshot.fromChannel(<String, dynamic>{});
      expect(snapshot.playing, isEmpty);
      expect(snapshot.lastPlaying, isNull);
    });

    test('reads both facts out of a full reply', () {
      final snapshot = MusicSessionSnapshot.fromChannel(<String, dynamic>{
        'playing': <Object?>['ytmusic'],
        'lastPlaying': 'spotify',
      });
      expect(snapshot.playing, <MusicProvider>[MusicProvider.ytmusic]);
      expect(snapshot.lastPlaying, MusicProvider.spotify);
    });

    test('a provider listed twice is still one playing service', () {
      final snapshot = MusicSessionSnapshot.fromChannel(<String, dynamic>{
        'playing': <Object?>['spotify', 'spotify'],
      });
      expect(snapshot.playing, <MusicProvider>[MusicProvider.spotify]);
    });

    test('an id a newer native build sends is dropped, not defaulted', () {
      final snapshot = MusicSessionSnapshot.fromChannel(<String, dynamic>{
        'playing': <Object?>['tidal', null, 42, 'ytmusic'],
        'lastPlaying': 'tidal',
      });
      expect(snapshot.playing, <MusicProvider>[MusicProvider.ytmusic]);
      expect(snapshot.lastPlaying, isNull);
    });
  });
}
