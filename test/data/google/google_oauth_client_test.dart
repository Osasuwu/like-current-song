import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:like_spotify_mobile_app/data/google/google_oauth_client.dart';

String fakeIdToken(Map<String, dynamic> claims) {
  String part(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'RS256'})}.${part(claims)}.signature';
}

http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

void main() {
  late List<http.Request> requests;

  GoogleOAuthClient clientReplying(http.Response Function(http.Request) reply) {
    return GoogleOAuthClient(MockClient((request) async {
      requests.add(request);
      return reply(request);
    }));
  }

  setUp(() => requests = <http.Request>[]);

  group('requestDeviceCode', () {
    test('posts client id + scope and parses Google\'s verification_url',
        () async {
      final client = clientReplying((_) => jsonResponse({
            'device_code': 'dev-1',
            'user_code': 'ABCD-EFGH',
            'verification_url': 'https://www.google.com/device',
            'expires_in': 1800,
            'interval': 5,
          }));

      final code = await client.requestDeviceCode(
        clientId: 'cid',
        scope: GoogleScopes.youTubeMusic,
      );

      expect(requests.single.url, GoogleOAuthClient.deviceCodeUri);
      expect(requests.single.bodyFields, {
        'client_id': 'cid',
        'scope': 'https://www.googleapis.com/auth/youtube openid',
      });
      expect(code.deviceCode, 'dev-1');
      expect(code.userCode, 'ABCD-EFGH');
      expect(code.verificationUrl, 'https://www.google.com/device');
      expect(code.expiresInSec, 1800);
      expect(code.intervalSec, 5);
    });

    test('accepts the RFC 8628 verification_uri spelling', () async {
      final client = clientReplying((_) => jsonResponse({
            'device_code': 'd',
            'user_code': 'u',
            'verification_uri': 'https://example.test/device',
          }));

      final code = await client.requestDeviceCode(
        clientId: 'cid',
        scope: GoogleScopes.youTubeMusic,
      );

      expect(code.verificationUrl, 'https://example.test/device');
      expect(code.intervalSec, 5);
    });

    test('the counter asks for the spreadsheets scope instead', () async {
      final client = clientReplying((_) => jsonResponse({
            'device_code': 'd',
            'user_code': 'u',
            'verification_url': 'https://www.google.com/device',
          }));

      await client.requestDeviceCode(
        clientId: 'cid',
        scope: GoogleScopes.spreadsheets,
      );

      expect(requests.single.bodyFields['scope'],
          'https://www.googleapis.com/auth/spreadsheets');
    });

    test('invalid_client throws GoogleOAuthException', () async {
      final client = clientReplying((_) => jsonResponse(
          {'error': 'invalid_client', 'error_description': 'Unauthorized'},
          401));

      await expectLater(
        client.requestDeviceCode(
          clientId: 'bad',
          scope: GoogleScopes.youTubeMusic,
        ),
        throwsA(isA<GoogleOAuthException>()
            .having((e) => e.error, 'error', 'invalid_client')
            .having((e) => e.statusCode, 'statusCode', 401)),
      );
    });

    test('a non-JSON error becomes http_<code>', () async {
      final client = clientReplying((_) => http.Response('<html>', 503));

      await expectLater(
        client.requestDeviceCode(
          clientId: 'cid',
          scope: GoogleScopes.youTubeMusic,
        ),
        throwsA(isA<GoogleOAuthException>()
            .having((e) => e.error, 'error', 'http_503')),
      );
    });
  });

  group('pollDeviceToken', () {
    Future<DevicePollResult> poll(http.Response response) => clientReplying(
          (_) => response,
        ).pollDeviceToken(
          clientId: 'cid',
          clientSecret: 'secret',
          deviceCode: 'dev-1',
        );

    test('sends the device_code grant', () async {
      await poll(jsonResponse({'error': 'authorization_pending'}, 428));

      expect(requests.single.url, GoogleOAuthClient.tokenUri);
      expect(requests.single.bodyFields, {
        'client_id': 'cid',
        'client_secret': 'secret',
        'device_code': 'dev-1',
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      });
    });

    test('authorization_pending -> pending', () async {
      expect(
        await poll(jsonResponse({'error': 'authorization_pending'}, 428)),
        isA<DevicePollPending>(),
      );
    });

    test('slow_down -> slow down', () async {
      expect(
        await poll(jsonResponse({'error': 'slow_down'}, 403)),
        isA<DevicePollSlowDown>(),
      );
    });

    test('access_denied and expired_token throw', () async {
      await expectLater(
        poll(jsonResponse({'error': 'access_denied'}, 403)),
        throwsA(isA<GoogleOAuthException>()
            .having((e) => e.error, 'error', 'access_denied')),
      );
      await expectLater(
        poll(jsonResponse({'error': 'expired_token'}, 400)),
        throwsA(isA<GoogleOAuthException>()
            .having((e) => e.error, 'error', 'expired_token')),
      );
    });

    test('success -> granted tokens', () async {
      final result = await poll(jsonResponse({
        'access_token': 'at',
        'refresh_token': 'rt',
        'expires_in': 3599,
        'id_token': fakeIdToken({'sub': '1234'}),
      }));

      final tokens = (result as DevicePollGranted).tokens;
      expect(tokens.accessToken, 'at');
      expect(tokens.refreshToken, 'rt');
      expect(tokens.expiresInSec, 3599);
      expect(decodeIdTokenSubject(tokens.idToken), '1234');
    });
  });

  test('refreshAccessToken sends the refresh_token grant', () async {
    final client = clientReplying(
        (_) => jsonResponse({'access_token': 'new', 'expires_in': 3600}));

    final tokens = await client.refreshAccessToken(
      clientId: 'cid',
      clientSecret: 'secret',
      refreshToken: 'rt',
    );

    expect(requests.single.url, GoogleOAuthClient.tokenUri);
    expect(requests.single.bodyFields, {
      'client_id': 'cid',
      'client_secret': 'secret',
      'refresh_token': 'rt',
      'grant_type': 'refresh_token',
    });
    expect(tokens.accessToken, 'new');
    expect(tokens.refreshToken, isNull);
  });

  group('decodeIdTokenSubject', () {
    test('reads sub from an unpadded base64url payload', () {
      // Claims chosen so the payload needs padding and uses '-'/'_'.
      final token = fakeIdToken({'sub': '10769150350006150715113082367', 'n': '??>>'});
      expect(decodeIdTokenSubject(token), '10769150350006150715113082367');
    });

    test('returns null for missing or malformed tokens', () {
      expect(decodeIdTokenSubject(null), isNull);
      expect(decodeIdTokenSubject('not-a-jwt'), isNull);
      expect(decodeIdTokenSubject('a.%%%.c'), isNull);
      expect(decodeIdTokenSubject(fakeIdToken({'email': 'x'})), isNull);
      expect(decodeIdTokenSubject(fakeIdToken({'sub': 42})), isNull);
    });
  });
}
