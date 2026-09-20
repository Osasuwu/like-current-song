import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/likes/like_counter_store.dart';
import '../../data/spotify/spotify_token_store.dart';
import '../../domain/entities/like_counter_config.dart';

class ServiceCredentialsState {
  const ServiceCredentialsState({
    this.spotifyClientId = '',
    this.counter = LikeCounterConfig.empty,
    this.loaded = false,
    this.spotifySaved = false,
    this.counterSaved = false,
    this.error,
  });

  /// The Spotify app's client ID. PKCE means there is no secret beside it.
  final String spotifyClientId;

  /// The shared like counter's spreadsheet and Google sign-in;
  /// [LikeCounterConfig.empty] means counts stay on this device.
  final LikeCounterConfig counter;

  /// False until the stores have been read once, so the fields are not
  /// prefilled with a blank that is merely "not read yet".
  final bool loaded;

  /// True right after a successful save, for a confirmation line.
  final bool spotifySaved;
  final bool counterSaved;

  /// Last failure, ready to show as-is.
  final String? error;

  bool get hasSpotifyClientId => spotifyClientId.isNotEmpty;

  ServiceCredentialsState copyWith({
    String? spotifyClientId,
    LikeCounterConfig? counter,
    bool? loaded,
    bool? spotifySaved,
    bool? counterSaved,
    String? error,
    bool clearError = false,
  }) {
    return ServiceCredentialsState(
      spotifyClientId: spotifyClientId ?? this.spotifyClientId,
      counter: counter ?? this.counter,
      loaded: loaded ?? this.loaded,
      spotifySaved: spotifySaved ?? this.spotifySaved,
      counterSaved: counterSaved ?? this.counterSaved,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Holds what the user types on *Connected services* — the Spotify client ID
/// and the optional shared counter's spreadsheet — and writes it to the same
/// stores the repositories read at call time.
///
/// The counter's Google sign-in is not here: that is a device flow, driven by
/// its own sign-in controller. This controller only reads the resulting
/// config back, so the card can say whether the counter is actually on.
class ServiceCredentialsController
    extends StateNotifier<ServiceCredentialsState> {
  ServiceCredentialsController({
    required SpotifyTokenStore spotifyTokenStore,
    required LikeCounterStore likeCounterStore,
    required Future<void> Function(LikeCounterConfig config)
        onLikeCounterConfigChanged,
  })  : _spotifyTokenStore = spotifyTokenStore,
        _likeCounterStore = likeCounterStore,
        _onLikeCounterConfigChanged = onLikeCounterConfigChanged,
        super(const ServiceCredentialsState());

  final SpotifyTokenStore _spotifyTokenStore;
  final LikeCounterStore _likeCounterStore;

  /// The native side keeps its own copy of the counter config (the like
  /// worker runs without Dart), so every change is pushed across.
  final Future<void> Function(LikeCounterConfig config)
      _onLikeCounterConfigChanged;

  Future<void> load() async {
    try {
      final clientId = await _spotifyTokenStore.readClientId();
      final counter = await _likeCounterStore.read();
      if (!mounted) return;
      state = state.copyWith(
        spotifyClientId: clientId?.trim() ?? '',
        counter: counter,
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

  /// A blank id turns the shared counter off, which is a legitimate choice;
  /// the Google sign-in is left alone either way.
  Future<void> saveCounterSpreadsheetId(String spreadsheetId) async {
    final trimmed = spreadsheetId.trim();
    try {
      await _likeCounterStore.saveSpreadsheetId(trimmed);
      final counter = await _likeCounterStore.read();
      await _onLikeCounterConfigChanged(counter);
      if (!mounted) return;
      state = state.copyWith(
        counter: counter,
        counterSaved: true,
        clearError: true,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        error: 'Could not save the counter settings: $error',
        counterSaved: false,
      );
    }
  }

  /// Re-reads the counter config, for after a sign-in or a sign-out changed
  /// it behind this controller's back.
  Future<void> refreshCounter() async {
    try {
      final counter = await _likeCounterStore.read();
      if (!mounted) return;
      state = state.copyWith(counter: counter, counterSaved: false);
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        error: 'Could not read the counter settings: $error',
      );
    }
  }
}
