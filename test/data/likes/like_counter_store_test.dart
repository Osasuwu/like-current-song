import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/data/likes/like_counter_store.dart';
import 'package:like_spotify_mobile_app/domain/entities/device_sign_in.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LikeCounterStore store;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    store = LikeCounterStore(const FlutterSecureStorage());
  });

  test('a fresh install reads as no counter at all', () async {
    final config = await store.read();

    expect(config.spreadsheetId, isEmpty);
    expect(config.hasCredentials, isFalse);
    expect(config.isSignedIn, isFalse);
    expect(config.isConfigured, isFalse);
  });

  test('the spreadsheet and the sign-in are stored apart', () async {
    await store.saveSpreadsheetId('sheet-1');
    await store.saveCredentials(
      const OAuthClientCredentials(clientId: 'gid', clientSecret: 'gsecret'),
    );
    await store.saveTokens(
      accessToken: 'access',
      refreshToken: 'refresh',
      expiresAt: DateTime.utc(2026, 9, 20, 12),
    );

    final config = await store.read();
    expect(config.spreadsheetId, 'sheet-1');
    expect(config.clientId, 'gid');
    expect(config.clientSecret, 'gsecret');
    expect(config.accessToken, 'access');
    expect(config.expiresAt, DateTime.utc(2026, 9, 20, 12));
  });

  test('signing out keeps the spreadsheet and the client', () async {
    await store.saveSpreadsheetId('sheet-1');
    await store.saveCredentials(
      const OAuthClientCredentials(clientId: 'gid', clientSecret: 'gsecret'),
    );
    await store.saveTokens(
      accessToken: 'access',
      refreshToken: 'refresh',
      expiresAt: DateTime.utc(2026),
    );

    await store.clearTokens();

    final config = await store.read();
    expect(config.isSignedIn, isFalse);
    expect(config.spreadsheetId, 'sheet-1');
    expect(config.hasCredentials, isTrue);
  });

  group('seed', () {
    test('fills a store that has never been written', () async {
      await store.seed(
        spreadsheetId: 'built-in-sheet',
        clientId: 'built-in-id',
        clientSecret: 'built-in-secret',
      );

      final config = await store.read();
      expect(config.spreadsheetId, 'built-in-sheet');
      expect(config.clientId, 'built-in-id');
      expect(config.clientSecret, 'built-in-secret');
    });

    test('never overwrites what the user saved', () async {
      await store.saveSpreadsheetId('typed-sheet');
      await store.saveCredentials(
        const OAuthClientCredentials(clientId: 'typed', clientSecret: 'typed-s'),
      );

      await store.seed(
        spreadsheetId: 'built-in-sheet',
        clientId: 'built-in-id',
        clientSecret: 'built-in-secret',
      );

      final config = await store.read();
      expect(config.spreadsheetId, 'typed-sheet');
      expect(config.clientId, 'typed');
      expect(config.clientSecret, 'typed-s');
    });

    test('a deliberately cleared value stays cleared', () async {
      // Turning the shared counter off writes an empty string, which is a
      // decision, not an absence — a rebuild must not undo it.
      await store.saveSpreadsheetId('');

      await store.seed(spreadsheetId: 'built-in-sheet');

      expect((await store.read()).spreadsheetId, isEmpty);
    });

    test('half a credential pair is no credential', () async {
      await store.seed(clientId: 'built-in-id', clientSecret: '');
      expect(await store.readCredentials(), isNull);

      await store.seed(clientId: '', clientSecret: 'built-in-secret');
      expect(await store.readCredentials(), isNull);
    });

    test('a credential pair half-written by hand is left alone', () async {
      await store.saveCredentials(
        const OAuthClientCredentials(clientId: 'typed', clientSecret: ''),
      );

      await store.seed(clientId: 'built-in-id', clientSecret: 'built-in-secret');

      final config = await store.read();
      expect(config.clientId, 'typed');
      expect(config.clientSecret, isEmpty);
    });

    test('the sign-in itself is never seeded', () async {
      await store.seed(
        spreadsheetId: 'built-in-sheet',
        clientId: 'built-in-id',
        clientSecret: 'built-in-secret',
      );

      expect((await store.read()).isSignedIn, isFalse);
    });

    test('a build with no defines writes nothing', () async {
      await store.seed();

      final config = await store.read();
      expect(config.spreadsheetId, isEmpty);
      expect(config.hasCredentials, isFalse);
    });
  });
}
