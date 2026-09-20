import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/data/likes/supabase_config_store.dart';
import 'package:like_spotify_mobile_app/data/spotify/spotify_token_store.dart';
import 'package:like_spotify_mobile_app/domain/entities/supabase_config.dart';
import 'package:like_spotify_mobile_app/presentation/state/service_credentials_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SpotifyTokenStore tokenStore;
  late SupabaseConfigStore configStore;
  late List<SupabaseConfig> pushedToNative;

  ServiceCredentialsController build() => ServiceCredentialsController(
        spotifyTokenStore: tokenStore,
        supabaseConfigStore: configStore,
        onSupabaseConfigChanged: (config) async => pushedToNative.add(config),
      );

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    tokenStore = SpotifyTokenStore(const FlutterSecureStorage());
    configStore = SupabaseConfigStore(const FlutterSecureStorage());
    pushedToNative = <SupabaseConfig>[];
  });

  test('loads what the stores already hold', () async {
    await tokenStore.saveClientId('stored-client-id');
    await configStore.save(
      const SupabaseConfig(url: 'https://p.supabase.co', anonKey: 'anon'),
    );

    final controller = build();
    await controller.load();

    expect(controller.state.loaded, isTrue);
    expect(controller.state.spotifyClientId, 'stored-client-id');
    expect(controller.state.hasSpotifyClientId, isTrue);
    expect(controller.state.supabase.anonKey, 'anon');
  });

  test('a fresh install loads as unconfigured, not as an error', () async {
    final controller = build();
    await controller.load();

    expect(controller.state.loaded, isTrue);
    expect(controller.state.hasSpotifyClientId, isFalse);
    expect(controller.state.supabase, SupabaseConfig.empty);
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

  test('saving the counter config tells the native side too', () async {
    final controller = build();

    await controller.saveSupabaseConfig(
      url: ' https://p.supabase.co ',
      anonKey: ' anon ',
    );

    expect(
      await configStore.read(),
      const SupabaseConfig(url: 'https://p.supabase.co', anonKey: 'anon'),
    );
    expect(controller.state.supabaseSaved, isTrue);
    expect(pushedToNative.single.url, 'https://p.supabase.co');
  });

  test('clearing both fields turns the shared counter off', () async {
    await configStore.save(
      const SupabaseConfig(url: 'https://p.supabase.co', anonKey: 'anon'),
    );
    final controller = build();

    await controller.saveSupabaseConfig(url: '', anonKey: '');

    expect((await configStore.read()).isConfigured, isFalse);
    expect(controller.state.supabaseSaved, isTrue);
    expect(pushedToNative.single, SupabaseConfig.empty);
  });

  test('half a counter config is refused', () async {
    final controller = build();

    await controller.saveSupabaseConfig(
      url: 'https://p.supabase.co',
      anonKey: '',
    );

    expect((await configStore.read()).isConfigured, isFalse);
    expect(controller.state.supabaseSaved, isFalse);
    expect(controller.state.error, contains('both'));
    expect(pushedToNative, isEmpty);
  });
}
