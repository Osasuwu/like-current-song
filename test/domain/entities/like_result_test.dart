import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/like_result.dart';

void main() {
  group('LikeResult', () {
    test('success is true when trackLiked and no error', () {
      const result = LikeResult(
        trackId: 'id',
        trackName: 'name',
        trackLiked: true,
        trackLikeCount: 1,
      );
      expect(result.success, true);
    });

    test('success is false when error message present', () {
      const result = LikeResult(
        trackId: 'id',
        trackName: 'name',
        trackLiked: true,
        trackLikeCount: 1,
        errorMessage: 'oops',
      );
      expect(result.success, false);
    });

    test('success is false when trackLiked is false', () {
      const result = LikeResult(
        trackId: 'id',
        trackName: 'name',
        trackLiked: false,
        trackLikeCount: 0,
      );
      expect(result.success, false);
    });

    test('defaults are correct', () {
      const result = LikeResult(
        trackId: 'id',
        trackName: 'name',
        trackLiked: true,
      );
      expect(result.removedFromArchive, false);
      expect(result.addedToBest, false);
      expect(result.followedArtistNames, isEmpty);
      expect(result.trackLikeCount, 0);
      expect(result.errorMessage, isNull);
    });
  });
}
