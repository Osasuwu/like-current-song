import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:like_spotify_mobile_app/data/ytmusic/google_oauth_client.dart';
import 'package:like_spotify_mobile_app/data/ytmusic/ytmusic_music_service_repository.dart';
import 'package:like_spotify_mobile_app/data/ytmusic/ytmusic_token_store.dart';
import 'package:like_spotify_mobile_app/domain/entities/device_sign_in.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_service_exceptions.dart';
import 'package:like_spotify_mobile_app/domain/entities/pending_like.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/mocks.dart';

String fakeIdToken(String sub) {
  String part(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'RS256'})}.${part({'sub': sub})}.sig';
}

http.Response jsonResponse(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

void main() {
  const credentials =
      OAuthClientCredentials(clientId: 'cid', clientSecret: 'secret');

  late Queue<Object> replies; // http.Response or an Exception to throw
  late List<http.Request> requests;
  late List<Duration> delays;
  late DateTime now;
  late YouTubeMusicTokenStore tokenStore;
  late MockPlatformServiceRepository platform;
  late YouTubeMusicServiceRepository repo;

  YouTubeMusicServiceRepository build({
    Future<void> Function(Duration)? delay,
  }) {
    final http.Client mockHttp = MockClient((request) async {
      requests.add(request);
      final reply = replies.removeFirst();
      if (reply is Exception) throw reply;
      return reply as http.Response;
    });
    return YouTubeMusicServiceRepository(
      oauthClient: GoogleOAuthClient(mockHttp),
      tokenStore: tokenStore,
      platformServiceRepository: platform,
      clock: () => now,
      delay: delay ??
          (d) async {
            delays.add(d);
            now = now.add(d);
          },
    );
  }

  DeviceSignInPrompt prompt({Duration expiresIn = const Duration(minutes: 30)}) =>
      DeviceSignInPrompt(
        deviceCode: 'dev-1',
        userCode: 'ABCD-EFGH',
        verificationUrl: 'https://www.google.com/device',
        expiresAt: now.add(expiresIn),
        pollInterval: const Duration(seconds: 5),
      );

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    replies = Queue<Object>();
    requests = <http.Request>[];
    delays = <Duration>[];
    now = DateTime.utc(2026, 9, 19, 12);
    tokenStore = YouTubeMusicTokenStore(const FlutterSecureStorage());
    platform = MockPlatformServiceRepository();
    when(() => platform.syncYouTubeMusicTokens(
          accessToken: any(named: 'accessToken'),
          refreshToken: any(named: 'refreshToken'),
          expiresAtEpochMs: any(named: 'expiresAtEpochMs'),
          clientId: any(named: 'clientId'),
          clientSecret: any(named: 'clientSecret'),
          userSub: any(named: 'userSub'),
        )).thenAnswer((_) async {});
    when(() => platform.clearYouTubeMusicTokens()).thenAnswer((_) async {});
    repo = build();
  });

  Future<void> signedInWith({required DateTime expiresAt}) async {
    await tokenStore.saveCredentials(credentials);
    await tokenStore.saveTokens(YouTubeMusicTokens(
      accessToken: 'old-access',
      refreshToken: 'rt',
      expiresAt: expiresAt,
      userSub: 'sub-1',
    ));
  }

  group('auth state + silent refresh', () {
    test('no tokens -> disconnected, no network', () async {
      final state = await repo.getAuthState();

      expect(state.connected, isFalse);
      expect(requests, isEmpty);
    });

    test('a fresh token is used as-is and exposes the account id', () async {
      await signedInWith(expiresAt: now.add(const Duration(hours: 1)));

      final state = await repo.getAuthState();

      expect(state.connected, isTrue);
      expect(state.accessToken, 'old-access');
      expect(state.accountId, 'sub-1');
      expect(requests, isEmpty);
    });

    test('a token near expiry is refreshed with the refresh_token grant',
        () async {
      await signedInWith(expiresAt: now.add(const Duration(minutes: 2)));
      replies.add(jsonResponse({'access_token': 'new-access', 'expires_in': 3600}));

      final state = await repo.getAuthState();

      expect(requests.single.url, GoogleOAuthClient.tokenUri);
      expect(requests.single.bodyFields, {
        'client_id': 'cid',
        'client_secret': 'secret',
        'refresh_token': 'rt',
        'grant_type': 'refresh_token',
      });
      expect(state.accessToken, 'new-access');
      expect(state.refreshToken, 'rt', reason: 'kept when Google omits it');
      expect(state.accountId, 'sub-1');

      final stored = await tokenStore.readTokens();
      expect(stored!.accessToken, 'new-access');
      expect(stored.expiresAt, now.add(const Duration(hours: 1)));
      verify(() => platform.syncYouTubeMusicTokens(
            accessToken: 'new-access',
            refreshToken: 'rt',
            expiresAtEpochMs:
                now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
            clientId: 'cid',
            clientSecret: 'secret',
            userSub: 'sub-1',
          )).called(1);
    });

    test('refreshIfNeeded refreshes an expired token', () async {
      await signedInWith(expiresAt: now.subtract(const Duration(minutes: 1)));
      replies.add(jsonResponse({'access_token': 'new-access', 'expires_in': 3600}));

      await repo.refreshIfNeeded();

      expect((await tokenStore.readTokens())!.accessToken, 'new-access');
    });

    test('invalid_grant signs out locally and natively', () async {
      await signedInWith(expiresAt: now.subtract(const Duration(minutes: 1)));
      replies.add(jsonResponse({'error': 'invalid_grant'}, 400));

      final state = await repo.getAuthState();

      expect(state.connected, isFalse);
      expect(await tokenStore.readTokens(), isNull);
      expect((await tokenStore.readCredentials())!.clientId, 'cid',
          reason: 'credentials survive sign-out');
      verify(() => platform.clearYouTubeMusicTokens()).called(1);
    });

    test('a network failure keeps the stored sign-in', () async {
      await signedInWith(expiresAt: now.subtract(const Duration(minutes: 1)));
      replies.add(http.ClientException('offline'));

      final state = await repo.getAuthState();

      expect(state.connected, isTrue);
      expect(state.accessToken, 'old-access');
      expect(await tokenStore.readTokens(), isNotNull);
    });
  });

  group('startSignIn', () {
    test('needs credentials first', () async {
      await expectLater(
        repo.startSignIn(),
        throwsA(isA<DeviceSignInException>().having((e) => e.failure,
            'failure', DeviceSignInFailure.missingCredentials)),
      );
      expect(requests, isEmpty);
    });

    test('returns the code to show', () async {
      await tokenStore.saveCredentials(credentials);
      replies.add(jsonResponse({
        'device_code': 'dev-1',
        'user_code': 'ABCD-EFGH',
        'verification_url': 'https://www.google.com/device',
        'expires_in': 1800,
        'interval': 5,
      }));

      final p = await repo.startSignIn();

      expect(p.userCode, 'ABCD-EFGH');
      expect(p.verificationUrl, 'https://www.google.com/device');
      expect(p.expiresAt, now.add(const Duration(minutes: 30)));
      expect(p.pollInterval, const Duration(seconds: 5));
    });

    test('invalid_client -> readable invalidClient failure', () async {
      await tokenStore.saveCredentials(credentials);
      replies.add(jsonResponse({'error': 'invalid_client'}, 401));

      await expectLater(
        repo.startSignIn(),
        throwsA(isA<DeviceSignInException>()
            .having((e) => e.failure, 'failure', DeviceSignInFailure.invalidClient)
            .having((e) => e.message, 'message',
                contains('TVs and Limited Input devices'))),
      );
    });

    test('offline -> network failure', () async {
      await tokenStore.saveCredentials(credentials);
      replies.add(http.ClientException('offline'));

      await expectLater(
        repo.startSignIn(),
        throwsA(isA<DeviceSignInException>().having(
            (e) => e.failure, 'failure', DeviceSignInFailure.network)),
      );
    });
  });

  group('waitForApproval', () {
    setUp(() => tokenStore.saveCredentials(credentials));

    test('polls through pending + slow_down, then stores and syncs tokens',
        () async {
      replies
        ..add(jsonResponse({'error': 'authorization_pending'}, 428))
        ..add(jsonResponse({'error': 'slow_down'}, 403))
        ..add(http.ClientException('blip')) // transient: keep polling
        ..add(jsonResponse({
          'access_token': 'at',
          'refresh_token': 'rt',
          'expires_in': 3600,
          'id_token': fakeIdToken('google-sub-42'),
        }));

      final state = await repo.waitForApproval(prompt());

      expect(delays, const [
        Duration(seconds: 5),
        Duration(seconds: 5),
        Duration(seconds: 10), // slow_down adds 5s
        Duration(seconds: 10),
      ]);
      expect(state.connected, isTrue);
      expect(state.accountId, 'google-sub-42');
      final stored = await tokenStore.readTokens();
      expect(stored!.refreshToken, 'rt');
      expect(stored.userSub, 'google-sub-42');
      verify(() => platform.syncYouTubeMusicTokens(
            accessToken: 'at',
            refreshToken: 'rt',
            expiresAtEpochMs: stored.expiresAt.millisecondsSinceEpoch,
            clientId: 'cid',
            clientSecret: 'secret',
            userSub: 'google-sub-42',
          )).called(1);
    });

    test('access_denied -> denied', () async {
      replies.add(jsonResponse({'error': 'access_denied'}, 403));

      await expectLater(
        repo.waitForApproval(prompt()),
        throwsA(isA<DeviceSignInException>()
            .having((e) => e.failure, 'failure', DeviceSignInFailure.denied)),
      );
      expect(await tokenStore.readTokens(), isNull);
    });

    test('expired_token -> expired', () async {
      replies.add(jsonResponse({'error': 'expired_token'}, 400));

      await expectLater(
        repo.waitForApproval(prompt()),
        throwsA(isA<DeviceSignInException>()
            .having((e) => e.failure, 'failure', DeviceSignInFailure.expired)),
      );
    });

    test('stops at the code expiry without another poll', () async {
      await expectLater(
        repo.waitForApproval(prompt(expiresIn: const Duration(seconds: 3))),
        throwsA(isA<DeviceSignInException>()
            .having((e) => e.failure, 'failure', DeviceSignInFailure.expired)),
      );
      expect(requests, isEmpty);
    });

    test('a grant without a refresh token is rejected', () async {
      replies.add(jsonResponse({'access_token': 'at', 'expires_in': 3600}));

      await expectLater(
        repo.waitForApproval(prompt()),
        throwsA(isA<DeviceSignInException>()),
      );
      expect(await tokenStore.readTokens(), isNull);
    });

    test('cancelSignIn stops the wait', () async {
      final repo = build(delay: (_) => Completer<void>().future); // never fires

      final wait = repo.waitForApproval(prompt());
      await Future<void>.delayed(Duration.zero);
      repo.cancelSignIn();

      await expectLater(
        wait,
        throwsA(isA<DeviceSignInException>().having(
            (e) => e.failure, 'failure', DeviceSignInFailure.cancelled)),
      );
      expect(requests, isEmpty);
    });
  });

  group('MusicServiceRepository', () {
    test('disconnect clears tokens here and natively, keeps credentials',
        () async {
      await signedInWith(expiresAt: now.add(const Duration(hours: 1)));

      await repo.disconnect();

      expect(await tokenStore.readTokens(), isNull);
      expect((await tokenStore.readCredentials())!.isComplete, isTrue);
      verify(() => platform.clearYouTubeMusicTokens()).called(1);
    });

    void likeReply(Map<String, dynamic> map) {
      when(() => platform.likeYouTubeMusicCurrentTrack())
          .thenAnswer((_) async => map);
    }

    test('a session like needs no sign-in and is a liked result', () async {
      likeReply({'outcome': 'liked', 'trackName': 'Song — Artist'});

      final result = await repo.likeCurrentTrack();

      expect(result.trackLiked, isTrue);
      expect(result.alreadyLiked, isFalse);
      expect(result.trackName, 'Song — Artist');
    });

    test('an already-liked song counts as liked', () async {
      likeReply({'outcome': 'already_liked', 'trackName': 'Song'});

      final result = await repo.likeCurrentTrack();

      expect(result.trackLiked, isTrue);
      expect(result.alreadyLiked, isTrue);
    });

    test('a counted like carries the shared counter value', () async {
      likeReply({'outcome': 'liked', 'trackName': 'Song', 'likeCount': 3});

      expect((await repo.likeCurrentTrack()).trackLikeCount, 3);
    });

    test('an already-liked song carries its count too', () async {
      likeReply({
        'outcome': 'already_liked',
        'trackName': 'Song',
        'likeCount': 2,
      });

      expect((await repo.likeCurrentTrack()).trackLikeCount, 2);
    });

    test('an uncounted like has no count', () async {
      likeReply({'outcome': 'liked', 'trackName': 'Song', 'likeCount': null});

      expect((await repo.likeCurrentTrack()).trackLikeCount, 0);
    });

    test('a cooldown skip is not a like', () async {
      likeReply({'outcome': 'cooldown', 'trackName': 'Song'});

      final result = await repo.likeCurrentTrack();

      expect(result.trackLiked, isFalse);
      expect(result.skippedCooldown, isTrue);
    });

    test('an API failure carries its HTTP status', () async {
      likeReply({'outcome': 'failed', 'message': 'forbidden', 'httpCode': 403});

      await expectLater(
        repo.likeCurrentTrack(),
        throwsA(
          isA<MusicServiceHttpException>()
              .having((e) => e.statusCode, 'statusCode', 403),
        ),
      );
    });

    test('a failure without a status is a plain like failure', () async {
      likeReply({
        'outcome': 'failed',
        'message': 'YouTube Music is not playing',
      });

      await expectLater(
        repo.likeCurrentTrack(),
        throwsA(
          isA<YouTubeMusicLikeException>()
              .having((e) => e is MusicServiceHttpException, 'http', isFalse)
              .having(
                (e) => e.toString(),
                'message',
                'YouTube Music is not playing',
              ),
        ),
      );
    });

    test('never replays queued likes', () async {
      expect(
        await repo.processPendingLikes([
          PendingLike(
            trackId: 'x',
            trackName: 'x',
            artistIds: const [],
            artistNames: const [],
            queuedAt: DateTime.utc(2025, 1, 1),
            providerId: MusicProvider.ytmusic.id,
          ),
        ]),
        0,
      );
      verifyZeroInteractions(platform);
    });

    test('does not claim Spotify auth callbacks', () async {
      expect(
        await repo.handleAuthCallback(Uri.parse('likespotify://auth-callback')),
        isFalse,
      );
    });

    test('saveClientCredentials trims whitespace', () async {
      await repo.saveClientCredentials(const OAuthClientCredentials(
        clientId: '  cid \n',
        clientSecret: ' secret ',
      ));

      final saved = await repo.loadClientCredentials();
      expect(saved!.clientId, 'cid');
      expect(saved.clientSecret, 'secret');
    });
  });
}
