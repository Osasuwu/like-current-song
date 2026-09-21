import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/like_destination.dart';

/// The pure half of the destination feature. `LikeDestination.kt` is the
/// Kotlin twin of this enum and `LikeDestinationTest.kt` mirrors these cases,
/// so the three like paths cannot drift apart.
void main() {
  group('legs', () {
    test('liked songs likes natively only', () {
      expect(LikeDestination.native.likesNatively, isTrue);
      expect(LikeDestination.native.addsToPlaylist, isFalse);
    });

    test('a playlist adds to the playlist only', () {
      expect(LikeDestination.playlist.likesNatively, isFalse);
      expect(LikeDestination.playlist.addsToPlaylist, isTrue);
    });

    test('both does both', () {
      expect(LikeDestination.both.likesNatively, isTrue);
      expect(LikeDestination.both.addsToPlaylist, isTrue);
    });
  });

  group('fromId', () {
    test('reads every id it writes', () {
      for (final destination in LikeDestination.values) {
        expect(LikeDestination.fromId(destination.id), destination);
      }
    });

    test('falls back to the default for a missing or unknown id', () {
      expect(LikeDestination.fromId(null), LikeDestination.native);
      expect(LikeDestination.fromId(''), LikeDestination.native);
      expect(LikeDestination.fromId('somewhere-new'), LikeDestination.native);
    });

    test('the default is the behaviour the app always had', () {
      expect(LikeDestination.defaultDestination, LikeDestination.native);
    });
  });

  group('resolve', () {
    test('keeps a destination that has the playlist name it needs', () {
      expect(
        LikeDestination.resolve(LikeDestination.playlist, 'Trigger likes'),
        LikeDestination.playlist,
      );
      expect(
        LikeDestination.resolve(LikeDestination.both, 'Trigger likes'),
        LikeDestination.both,
      );
    });

    test('degrades to liked songs when the name is missing', () {
      expect(
        LikeDestination.resolve(LikeDestination.playlist, '   '),
        LikeDestination.native,
      );
      expect(
        LikeDestination.resolve(LikeDestination.both, ''),
        LikeDestination.native,
      );
    });

    test('leaves liked songs alone whatever the name is', () {
      expect(
        LikeDestination.resolve(LikeDestination.native, ''),
        LikeDestination.native,
      );
      expect(
        LikeDestination.resolve(LikeDestination.native, 'Trigger likes'),
        LikeDestination.native,
      );
    });
  });
}
