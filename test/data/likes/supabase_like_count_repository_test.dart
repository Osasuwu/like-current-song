import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:like_spotify_mobile_app/data/likes/supabase_like_count_repository.dart';
import 'package:like_spotify_mobile_app/domain/entities/supabase_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  const configured = SupabaseConfig(
    url: 'https://project.supabase.co',
    anonKey: 'anon-key',
  );

  /// Records what the repository asked Supabase for, and answers [body].
  ({http.Client client, List<http.Request> requests}) recordingClient(
    String body, {
    int status = 200,
  }) {
    final requests = <http.Request>[];
    return (
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(body, status);
      }),
      requests: requests,
    );
  }

  test('an unconfigured project counts locally and never calls out', () async {
    final spy = recordingClient('7');
    final repo = SupabaseLikeCountRepository(
      readConfig: () async => SupabaseConfig.empty,
      userIdGetter: () => 'user-1',
      httpClient: spy.client,
    );

    expect(await repo.incrementTrackLikeCount('track-1'), 1);
    expect(await repo.incrementTrackLikeCount('track-1'), 2);
    expect(spy.requests, isEmpty);
  });

  test('a configured project is incremented over the RPC', () async {
    final spy = recordingClient('42');
    final repo = SupabaseLikeCountRepository(
      readConfig: () async => configured,
      userIdGetter: () => 'user-1',
      httpClient: spy.client,
    );

    expect(await repo.incrementTrackLikeCount('track-1'), 42);

    expect(spy.requests, hasLength(1));
    final request = spy.requests.single;
    expect(
      request.url.toString(),
      'https://project.supabase.co/rest/v1/rpc/increment_track_like',
    );
    expect(request.headers['apikey'], 'anon-key');
    expect(request.headers['Authorization'], 'Bearer anon-key');
    expect(
      jsonDecode(request.body),
      <String, String>{'p_user_id': 'user-1', 'p_track_id': 'track-1'},
    );
  });

  test('config appearing later is picked up without a rebuild', () async {
    final spy = recordingClient('42');
    var config = SupabaseConfig.empty;
    final repo = SupabaseLikeCountRepository(
      readConfig: () async => config,
      userIdGetter: () => 'user-1',
      httpClient: spy.client,
    );

    expect(await repo.incrementTrackLikeCount('track-1'), 1);

    config = configured;

    expect(await repo.incrementTrackLikeCount('track-1'), 42);
    expect(spy.requests, hasLength(1));
  });

  test('a signed-out user counts locally', () async {
    final spy = recordingClient('42');
    final repo = SupabaseLikeCountRepository(
      readConfig: () async => configured,
      userIdGetter: () => null,
      httpClient: spy.client,
    );

    expect(await repo.incrementTrackLikeCount('track-1'), 1);
    expect(spy.requests, isEmpty);
  });

  test('a failing RPC falls back to the local count', () async {
    final spy = recordingClient('nope', status: 500);
    final repo = SupabaseLikeCountRepository(
      readConfig: () async => configured,
      userIdGetter: () => 'user-1',
      httpClient: spy.client,
    );

    expect(await repo.incrementTrackLikeCount('track-1'), 1);
    expect(spy.requests, hasLength(1));
  });

  test('an unreadable store counts locally rather than failing the like',
      () async {
    final spy = recordingClient('42');
    final repo = SupabaseLikeCountRepository(
      readConfig: () async => throw Exception('keystore locked'),
      userIdGetter: () => 'user-1',
      httpClient: spy.client,
    );

    expect(await repo.incrementTrackLikeCount('track-1'), 1);
    expect(spy.requests, isEmpty);
  });
}
