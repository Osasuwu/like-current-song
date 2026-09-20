import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/entities/supabase_config.dart';

/// What a `--dart-define-from-file=.env` build was compiled with. Only ever a
/// seed for [SupabaseConfigStore.seed]; once the store holds anything, that
/// wins.
const _envSupabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _envSupabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

/// The shared like counter's Supabase project, typed into *Connected
/// services* and kept next to the service tokens.
class SupabaseConfigStore {
  SupabaseConfigStore(this._storage);

  static const _keyUrl = 'supabase_url';
  static const _keyAnonKey = 'supabase_anon_key';

  final FlutterSecureStorage _storage;

  /// [SupabaseConfig.empty] until something is stored: no project configured
  /// is the normal state, not an error.
  Future<SupabaseConfig> read() async => SupabaseConfig(
        url: await _storage.read(key: _keyUrl) ?? '',
        anonKey: await _storage.read(key: _keyAnonKey) ?? '',
      );

  Future<void> save(SupabaseConfig config) async {
    await _storage.write(key: _keyUrl, value: config.url);
    await _storage.write(key: _keyAnonKey, value: config.anonKey);
  }

  /// Carries a build-time `--dart-define` config into the store, once, so an
  /// install built from `.env` keeps counting without retyping anything.
  ///
  /// Only a store that has never been written is seeded — a user who cleared
  /// the fields stays cleared. Half a config is no config, so both halves
  /// have to be there.
  Future<void> seed({
    String url = _envSupabaseUrl,
    String anonKey = _envSupabaseAnonKey,
  }) async {
    if (url.isEmpty || anonKey.isEmpty) return;
    if (await _storage.read(key: _keyUrl) != null) return;
    if (await _storage.read(key: _keyAnonKey) != null) return;
    await save(SupabaseConfig(url: url, anonKey: anonKey));
  }
}
