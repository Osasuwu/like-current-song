import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/likes/supabase_config_store.dart';
import '../../data/spotify/spotify_token_store.dart';
import '../../domain/entities/supabase_config.dart';

class ServiceCredentialsState {
  const ServiceCredentialsState({
    this.spotifyClientId = '',
    this.supabase = SupabaseConfig.empty,
    this.loaded = false,
    this.spotifySaved = false,
    this.supabaseSaved = false,
    this.error,
  });

  /// The Spotify app's client ID. PKCE means there is no secret beside it.
  final String spotifyClientId;

  /// The shared like counter's project; [SupabaseConfig.empty] means counts
  /// stay on this device.
  final SupabaseConfig supabase;

  /// False until the stores have been read once, so the fields are not
  /// prefilled with a blank that is merely "not read yet".
  final bool loaded;

  /// True right after a successful save, for a confirmation line.
  final bool spotifySaved;
  final bool supabaseSaved;

  /// Last failure, ready to show as-is.
  final String? error;

  bool get hasSpotifyClientId => spotifyClientId.isNotEmpty;

  ServiceCredentialsState copyWith({
    String? spotifyClientId,
    SupabaseConfig? supabase,
    bool? loaded,
    bool? spotifySaved,
    bool? supabaseSaved,
    String? error,
    bool clearError = false,
  }) {
    return ServiceCredentialsState(
      spotifyClientId: spotifyClientId ?? this.spotifyClientId,
      supabase: supabase ?? this.supabase,
      loaded: loaded ?? this.loaded,
      spotifySaved: spotifySaved ?? this.spotifySaved,
      supabaseSaved: supabaseSaved ?? this.supabaseSaved,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Holds what the user types on *Connected services* — the Spotify client ID
/// and the optional shared-counter project — and writes it to the same stores
/// the repositories read at call time.
class ServiceCredentialsController
    extends StateNotifier<ServiceCredentialsState> {
  ServiceCredentialsController({
    required SpotifyTokenStore spotifyTokenStore,
    required SupabaseConfigStore supabaseConfigStore,
    required Future<void> Function(SupabaseConfig config)
        onSupabaseConfigChanged,
  })  : _spotifyTokenStore = spotifyTokenStore,
        _supabaseConfigStore = supabaseConfigStore,
        _onSupabaseConfigChanged = onSupabaseConfigChanged,
        super(const ServiceCredentialsState());

  final SpotifyTokenStore _spotifyTokenStore;
  final SupabaseConfigStore _supabaseConfigStore;

  /// The native side keeps its own copy of the counter config (the like
  /// worker runs without Dart), so every change is pushed across.
  final Future<void> Function(SupabaseConfig config) _onSupabaseConfigChanged;

  Future<void> load() async {
    try {
      final clientId = await _spotifyTokenStore.readClientId();
      final supabase = await _supabaseConfigStore.read();
      if (!mounted) return;
      state = state.copyWith(
        spotifyClientId: clientId?.trim() ?? '',
        supabase: supabase,
        loaded: true,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        loaded: true,
        error: 'Could not read saved credentials: $error',
      );
    }
  }

  Future<void> saveSpotifyClientId(String clientId) async {
    final trimmed = clientId.trim();
    if (trimmed.isEmpty) {
      state = state.copyWith(
        error: 'Enter your Spotify client ID.',
        spotifySaved: false,
      );
      return;
    }
    try {
      await _spotifyTokenStore.saveClientId(trimmed);
      if (!mounted) return;
      state = state.copyWith(
        spotifyClientId: trimmed,
        spotifySaved: true,
        clearError: true,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        error: 'Could not save the client ID: $error',
        spotifySaved: false,
      );
    }
  }

  /// Both blank turns the shared counter off, which is a legitimate choice;
  /// half a config is not, because it could only ever fail at like time.
  Future<void> saveSupabaseConfig({
    required String url,
    required String anonKey,
  }) async {
    final config = SupabaseConfig(url: url.trim(), anonKey: anonKey.trim());
    final blank = config.url.isEmpty && config.anonKey.isEmpty;
    if (!blank && !config.isConfigured) {
      state = state.copyWith(
        error: 'Enter both the project URL and the anon key, or leave both '
            'blank to count likes on this device only.',
        supabaseSaved: false,
      );
      return;
    }
    try {
      await _supabaseConfigStore.save(config);
      await _onSupabaseConfigChanged(config);
      if (!mounted) return;
      state = state.copyWith(
        supabase: config,
        supabaseSaved: true,
        clearError: true,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        error: 'Could not save the counter settings: $error',
        supabaseSaved: false,
      );
    }
  }
}
