import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app.dart';
import 'data/likes/like_counter_store.dart';
import 'data/spotify/spotify_token_store.dart';
import 'data/ytmusic/ytmusic_token_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _seedCompileTimeCredentials();
  runApp(const ProviderScope(child: LikeSpotifyApp()));
}

/// Moves `--dart-define` credentials into the stores the app reads from, once.
///
/// A build made from `.env` should stay configured after the move to in-app
/// credentials; from then on whatever *Connected services* wrote wins, so this
/// only ever fills stores that have never been written.
Future<void> _seedCompileTimeCredentials() async {
  const storage = FlutterSecureStorage();
  try {
    await SpotifyTokenStore(storage).seedClientId();
    await YouTubeMusicTokenStore(storage).seedCredentials();
    await LikeCounterStore(storage).seed();
  } catch (error) {
    // Unreadable secure storage is the credentials screen's problem, not a
    // reason to refuse to start.
    debugPrint('Could not seed build-time credentials: $error');
  }
}
