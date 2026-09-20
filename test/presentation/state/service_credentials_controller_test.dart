import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/data/likes/counter_spreadsheet_creator.dart';
import 'package:like_spotify_mobile_app/data/likes/like_counter_store.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_token_store.dart';
import 'package:like_spotify_mobile_app/domain/entities/device_sign_in.dart';
import 'package:like_spotify_mobile_app/domain/entities/like_counter_config.dart';
import 'package:like_spotify_mobile_app/presentation/state/service_credentials_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SpotifyTokenStore tokenStore;
  late LikeCounterStore counterStore;
  late List<LikeCounterConfig> pushedToNative;
  late int createCalls;
  late Future<CreatedCounterSpreadsheet> Function() createSheet;

  ServiceCredentialsController build() => ServiceCredentialsController(
        spotifyTokenStore: tokenStore,
        likeCounterStore: counterStore,
        onLikeCounterConfigChanged: (config) async =>
            pushedToNative.add(config),
        createCounterSheet: () {
          createCalls++;
          return createSheet();
        },
      );

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    tokenStore = SpotifyTokenStore(const FlutterSecureStorage());
    counterStore = LikeCounterStore(const FlutterSecureStorage());
    pushedToNative = <LikeCounterConfig>[];
    createCalls = 0;
    createSheet = () async => const CreatedCounterSpreadsheet(
          spreadsheetId: 'made-1',
          url: 'https://docs.google.com/spreadsheets/d/made-1/edit',
        );
  });

  test('loads what the stores already hold', () async {
    await tokenStore.saveClientId('stored-client-id');
    await counterStore.saveSpreadsheetId('sheet-1');
    await counterStore.saveCredentials(
      const OAuthClientCredentials(clientId: 'gid', clientSecret: 'gsecret'),
    );

    final controller = build();
    await controller.load();

    expect(controller.state.loaded, isTrue);
    expect(controller.state.spotifyClientId, 'stored-client-id');
    expect(controller.state.hasSpotifyClientId, isTrue);
    expect(controller.state.counter.spreadsheetId, 'sheet-1');
    expect(controller.state.counter.hasCredentials, isTrue);
  });

  test('a fresh install loads as unconfigured, not as an error', () async {
    final controller = build();
    await controller.load();

    expect(controller.state.loaded, isTrue);
    expect(controller.state.hasSpotifyClientId, isFalse);
    expect(controller.state.counter, LikeCounterConfig.empty);
    expect(controller.state.error, isNull);
  });

  test('saving a client ID writes it through, trimmed', () async {
    final controller = build();

    await controller.saveSpotifyClientId('  client-abc  ');

    expect(await tokenStore.readClientId(), 'client-abc');
    expect(controller.state.spotifyClientId, 'client-abc');
    expect(controller.state.spotifySaved, isTrue);
    expect(controller.state.error, isNull);
  });

  test('an empty client ID is refused rather than stored', () async {
    final controller = build();

    await controller.saveSpotifyClientId('   ');

    expect(await tokenStore.readClientId(), isNull);
    expect(controller.state.spotifySaved, isFalse);
    expect(controller.state.error, 'Enter your Spotify client ID.');
  });

  test('saving the spreadsheet tells the native side too', () async {
    final controller = build();

    await controller.saveCounterSpreadsheetId('  sheet-1  ');

    expect((await counterStore.read()).spreadsheetId, 'sheet-1');
    expect(controller.state.counter.spreadsheetId, 'sheet-1');
    expect(controller.state.counterSaved, isTrue);
    expect(pushedToNative.single.spreadsheetId, 'sheet-1');
  });

  test('clearing the spreadsheet turns the shared counter off', () async {
    await counterStore.saveSpreadsheetId('sheet-1');
    final controller = build();

    await controller.saveCounterSpreadsheetId('');

    expect((await counterStore.read()).isConfigured, isFalse);
    expect(controller.state.counterSaved, isTrue);
    expect(pushedToNative.single.spreadsheetId, isEmpty);
  });

  test('clearing the spreadsheet leaves the Google sign-in alone', () async {
    await counterStore.saveCredentials(
      const OAuthClientCredentials(clientId: 'gid', clientSecret: 'gsecret'),
    );
    await counterStore.saveTokens(
      accessToken: 'access',
      refreshToken: 'refresh',
      expiresAt: DateTime.utc(2026, 9, 20),
    );
    final controller = build();

    await controller.saveCounterSpreadsheetId('');

    final stored = await counterStore.read();
    expect(stored.refreshToken, 'refresh');
    expect(stored.hasCredentials, isTrue);
    expect(controller.state.counter.isSignedIn, isTrue);
  });

  test('creating a spreadsheet stores it and tells the native side', () async {
    final controller = build();
    await controller.load();

    await controller.createCounterSpreadsheet();

    expect(createCalls, 1);
    expect((await counterStore.read()).spreadsheetId, 'made-1');
    expect(controller.state.counter.spreadsheetId, 'made-1');
    expect(controller.state.createdCounter?.spreadsheetId, 'made-1');
    expect(
      controller.state.createdCounter?.url,
      'https://docs.google.com/spreadsheets/d/made-1/edit',
    );
    expect(controller.state.counterCreating, isFalse);
    expect(controller.state.counterSaved, isTrue);
    expect(controller.state.error, isNull);
    expect(pushedToNative.single.spreadsheetId, 'made-1');
  });

  test('a second spreadsheet is refused while one is configured', () async {
    await counterStore.saveSpreadsheetId('sheet-1');
    final controller = build();
    await controller.load();

    await controller.createCounterSpreadsheet();

    expect(createCalls, 0);
    expect((await counterStore.read()).spreadsheetId, 'sheet-1');
    expect(controller.state.error, contains('already set up'));
    expect(controller.state.error, contains('sheet-1'));
  });

  test('a refusal from Google is shown in its own words', () async {
    createSheet = () async => throw const CounterSpreadsheetException(
          'Sign in to Google for the like counter first.',
        );
    final controller = build();
    await controller.load();

    await controller.createCounterSpreadsheet();

    expect(
      controller.state.error,
      'Sign in to Google for the like counter first.',
    );
    expect(controller.state.counterCreating, isFalse);
    expect(controller.state.createdCounter, isNull);
    expect((await counterStore.read()).spreadsheetId, isEmpty);
  });

  test('pasting a different ID drops the created panel', () async {
    final controller = build();
    await controller.load();
    await controller.createCounterSpreadsheet();
    expect(controller.state.createdCounter, isNotNull);

    await controller.saveCounterSpreadsheetId('household-sheet');

    expect(controller.state.createdCounter, isNull);
    expect(controller.state.counter.spreadsheetId, 'household-sheet');
  });

  test('refreshCounter picks up a sign-in made elsewhere', () async {
    final controller = build();
    await controller.load();
    expect(controller.state.counter.isSignedIn, isFalse);

    await counterStore.saveTokens(
      accessToken: 'access',
      refreshToken: 'refresh',
      expiresAt: DateTime.utc(2026, 9, 20),
    );
    await controller.refreshCounter();

    expect(controller.state.counter.isSignedIn, isTrue);
  });
}
