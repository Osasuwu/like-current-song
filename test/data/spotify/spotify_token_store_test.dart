import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_token_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SpotifyTokenStore store;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    store = SpotifyTokenStore(const FlutterSecureStorage());
  });

  test('a saved client ID reads back', () async {
    expect(await store.readClientId(), isNull);

    await store.saveClientId('client-abc');

    expect(await store.readClientId(), 'client-abc');
  });

  test('disconnecting drops the tokens but keeps the client ID', () async {
    await store.saveClientId('client-abc');
    await store.save(
      accessToken: 'access',
      refreshToken: 'refresh',
      expiresAtEpochSec: 1700000000,
    );

    await store.clear();

    expect(await store.readAccessToken(), isNull);
    expect(await store.readRefreshToken(), isNull);
    expect(await store.readExpiryEpochSec(), isNull);
    expect(
      await store.readClientId(),
      'client-abc',
      reason: 'reconnecting should not mean retyping the client ID',
    );
  });

  group('seeding from a --dart-define build', () {
    test('fills a store that has never been written', () async {
      await store.seedClientId(clientId: 'from-env');

      expect(await store.readClientId(), 'from-env');
    });

    test('leaves what the user saved alone', () async {
      await store.saveClientId('typed-in-app');

      await store.seedClientId(clientId: 'from-env');

      expect(await store.readClientId(), 'typed-in-app');
    });

    test('a deliberately cleared client ID is not re-seeded', () async {
      await store.saveClientId('');

      await store.seedClientId(clientId: 'from-env');

      expect(await store.readClientId(), '');
    });

    test('an unconfigured build writes nothing', () async {
      await store.seedClientId(clientId: '');

      expect(await store.readClientId(), isNull);
    });
  });
}
