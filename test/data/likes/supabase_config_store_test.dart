import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/data/likes/supabase_config_store.dart';
import 'package:like_spotify_mobile_app/domain/entities/supabase_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SupabaseConfigStore store;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    store = SupabaseConfigStore(const FlutterSecureStorage());
  });

  test('nothing stored reads as unconfigured', () async {
    expect(await store.read(), SupabaseConfig.empty);
    expect((await store.read()).isConfigured, isFalse);
  });

  test('a saved project reads back', () async {
    await store.save(
      const SupabaseConfig(url: 'https://p.supabase.co', anonKey: 'anon-key'),
    );

    final config = await store.read();
    expect(config.url, 'https://p.supabase.co');
    expect(config.anonKey, 'anon-key');
    expect(config.isConfigured, isTrue);
  });

  test('saving blanks turns the shared counter off', () async {
    await store.save(
      const SupabaseConfig(url: 'https://p.supabase.co', anonKey: 'anon-key'),
    );

    await store.save(SupabaseConfig.empty);

    expect((await store.read()).isConfigured, isFalse);
  });

  group('seeding from a --dart-define build', () {
    test('fills a store that has never been written', () async {
      await store.seed(url: 'https://env.supabase.co', anonKey: 'env-key');

      expect(
        await store.read(),
        const SupabaseConfig(url: 'https://env.supabase.co', anonKey: 'env-key'),
      );
    });

    test('leaves what the user saved alone', () async {
      await store.save(
        const SupabaseConfig(url: 'https://mine.supabase.co', anonKey: 'mine'),
      );

      await store.seed(url: 'https://env.supabase.co', anonKey: 'env-key');

      expect(
        await store.read(),
        const SupabaseConfig(url: 'https://mine.supabase.co', anonKey: 'mine'),
      );
    });

    test('a deliberately cleared config is not re-seeded', () async {
      await store.save(SupabaseConfig.empty);

      await store.seed(url: 'https://env.supabase.co', anonKey: 'env-key');

      expect((await store.read()).isConfigured, isFalse);
    });

    test('half a build-time config writes nothing', () async {
      await store.seed(url: 'https://env.supabase.co', anonKey: '');

      expect(await store.read(), SupabaseConfig.empty);
    });
  });
}
