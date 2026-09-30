import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/spotify_auth_state.dart';

void main() {
  group('SpotifyAuthState', () {
    group('disconnected factory', () {
      test('creates state with all fields null', () {
        final state = const SpotifyAuthState.disconnected();

        expect(state.accessToken, isNull);
        expect(state.refreshToken, isNull);
        expect(state.expiresAt, isNull);
      });

      test('sets connected to false', () {
        final state = const SpotifyAuthState.disconnected();

        expect(state.connected, equals(false));
      });

      test('isExpired returns false when all fields are null', () {
        final state = const SpotifyAuthState.disconnected();

        expect(state.isExpired, equals(false));
      });
    });

    group('isExpired getter', () {
      test('returns true when expiresAt is in the past', () {
        final expiresAt = DateTime.now().toUtc().subtract(Duration(hours: 1));
        final state = SpotifyAuthState(
          accessToken: 'token',
          refreshToken: 'refresh',
          expiresAt: expiresAt,
          connected: true,
        );

        expect(state.isExpired, equals(true));
      });

      test('returns false when expiresAt is in the future', () {
        final expiresAt = DateTime.now().toUtc().add(Duration(hours: 1));
        final state = SpotifyAuthState(
          accessToken: 'token',
          refreshToken: 'refresh',
          expiresAt: expiresAt,
          connected: true,
        );

        expect(state.isExpired, equals(false));
      });

      test('returns false when expiresAt is null', () {
        final state = SpotifyAuthState(
          accessToken: 'token',
          refreshToken: 'refresh',
          expiresAt: null,
          connected: true,
        );

        expect(state.isExpired, equals(false));
      });

      test('returns false when expiresAt is slightly in the future', () {
        final state = SpotifyAuthState(
          accessToken: 'token',
          refreshToken: 'refresh',
          expiresAt: DateTime.now().toUtc().add(Duration(seconds: 10)),
          connected: true,
        );

        expect(state.isExpired, equals(false));
      });
    });
  });
}
