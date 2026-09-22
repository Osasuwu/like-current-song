import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:like_spotify_mobile_app/data/google/google_oauth_client.dart';
import 'package:like_spotify_mobile_app/data/likes/google_sheets_like_count_repository.dart';
import 'package:like_spotify_mobile_app/data/likes/like_counter_account.dart';
import 'package:like_spotify_mobile_app/data/likes/like_counter_store.dart';
import 'package:like_spotify_mobile_app/data/likes/shared_prefs_like_count_repository.dart';
import 'package:like_spotify_mobile_app/domain/entities/app_log.dart';
import 'package:like_spotify_mobile_app/domain/entities/device_sign_in.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/mocks.dart';

/// What a like sees when the counter's Google token cannot be renewed.
///
/// The token the counter holds is short-lived, so on most likes the refresh
/// grant runs first. When Google says no, the Logs screen has to say *which*
/// no it was: a revoked sign-in is fixed by signing in again, a rejected
/// client is not.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockPlatformServiceRepository platform;
  final logs = <AppLog>[];

  setUp(() {
    logs.clear();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    platform = MockPlatformServiceRepository();
    when(() => platform.syncLikeCounterConfig(
          spreadsheetId: any(named: 'spreadsheetId'),
          clientId: any(named: 'clientId'),
          clientSecret: any(named: 'clientSecret'),
          accessToken: any(named: 'accessToken'),
          refreshToken: any(named: 'refreshToken'),
          expiresAtEpochMs: any(named: 'expiresAtEpochMs'),
        )).thenAnswer((_) async {});
  });

  /// A counter that is signed in but whose access token expired an hour ago,
  /// so the next like has to run the refresh grant. The token values here are
  /// made up; nothing real is read.
  Future<LikeCounterAccount> signedInAccount(http.Client client) async {
    final store = LikeCounterStore(const FlutterSecureStorage());
    await store.saveSpreadsheetId('sheet-1');
    await store.saveCredentials(
      const OAuthClientCredentials(clientId: 'gid', clientSecret: 'gsecret'),
    );
    await store.saveTokens(
      accessToken: 'stale-access',
      refreshToken: 'stored-refresh',
      expiresAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
    );
    return LikeCounterAccount(
      oauthClient: GoogleOAuthClient(client),
      store: store,
      platformServiceRepository: platform,
    );
  }

  /// The real wiring: the repository asks the account for a token, exactly as
  /// `music_service_factory.dart` and `app_providers.dart` wire it up.
  GoogleSheetsLikeCountRepository counterOver(
    LikeCounterAccount account,
    http.Client sheets,
  ) =>
      GoogleSheetsLikeCountRepository(
        readSpreadsheetId: () async => 'sheet-1',
        readAccessToken: account.freshAccessToken,
        userIdGetter: () async => 'user-1',
        appendLog: (log) async => logs.add(log),
        localCounts: SharedPrefsLikeCountRepository(),
        httpClient: sheets,
      );

  /// Answers the OAuth token endpoint with [error] and leaves everything else
  /// alone — the sheet is never reached when the token cannot be renewed.
  http.Client tokenEndpointRefusing(
    String error, {
    int status = 401,
    String? description,
  }) =>
      MockClient((request) async {
        if (request.url != GoogleOAuthClient.tokenUri) {
          return http.Response('unexpected ${request.url}', 500);
        }
        return http.Response(
          jsonEncode(<String, String>{
            'error': error,
            'error_description': ?description,
          }),
          status,
          headers: const <String, String>{
            'content-type': 'application/json',
          },
        );
      });

  test('a rejected client says so instead of "not signed in"', () async {
    final account = await signedInAccount(tokenEndpointRefusing(
      'invalid_client',
      description: 'The provided client secret is invalid.',
    ));
    final repo = counterOver(
      account,
      MockClient((_) async => http.Response('unreachable', 500)),
    );

    // The like still counts locally; that part already worked.
    expect(await repo.incrementTrackLikeCount('track-1'), 1);

    expect(logs, hasLength(1));
    final message = logs.single.message;
    expect(message, contains('invalid_client'));
    expect(
      message,
      contains('The provided client secret is invalid.'),
      reason: 'the reason Google gave has to reach the Logs screen',
    );
    expect(
      message,
      isNot(contains('not signed in')),
      reason: 'the counter *is* signed in; signing in again fixes nothing',
    );
    expect(logs.single.httpCode, 401);
  });

  test('a revoked sign-in still says sign in again', () async {
    final account = await signedInAccount(tokenEndpointRefusing(
      'invalid_grant',
      status: 400,
      description: 'Token has been expired or revoked.',
    ));
    final repo = counterOver(
      account,
      MockClient((_) async => http.Response('unreachable', 500)),
    );

    expect(await repo.incrementTrackLikeCount('track-1'), 1);

    expect(logs, hasLength(1));
    expect(
      logs.single.message,
      contains('Connected services'),
      reason: 'a revoked sign-in really is fixed by signing in again',
    );
    // And the dead tokens are gone, so the next like does not retry them.
    final config = await LikeCounterStore(const FlutterSecureStorage()).read();
    expect(config.isSignedIn, isFalse);
  });

  test('an unreachable Google is not reported as a sign-in problem', () async {
    final account = await signedInAccount(
      MockClient((_) async => throw const SocketishFailure()),
    );
    final repo = counterOver(
      account,
      MockClient((_) async => http.Response('unreachable', 500)),
    );

    expect(await repo.incrementTrackLikeCount('track-1'), 1);

    expect(logs, hasLength(1));
    expect(logs.single.message, isNot(contains('not signed in')));
    // Still signed in: a flaky network must not sign the counter out.
    final config = await LikeCounterStore(const FlutterSecureStorage()).read();
    expect(config.isSignedIn, isTrue);
  });
}

/// Stands in for a dropped connection, which arrives as some plain exception.
class SocketishFailure implements Exception {
  const SocketishFailure();

  @override
  String toString() => 'Connection closed before full header was received';
}
