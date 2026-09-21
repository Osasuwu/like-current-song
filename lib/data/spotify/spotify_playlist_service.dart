import 'package:flutter/foundation.dart';

import 'spotify_client.dart';

/// Manages playlist lookup (paginated search with in-memory cache), creation,
/// and track add/remove via SpotifyClient.
class SpotifyPlaylistService {
  final SpotifyClient _client;

  SpotifyPlaylistService(this._client);

  // In-memory cache: playlistName -> playlistId, with timestamp.
  final Map<String, String> _cache = <String, String>{};
  DateTime _cacheTimestamp = DateTime.fromMillisecondsSinceEpoch(0);
  static const _cacheTtl = Duration(hours: 12);

  String? _cachedUserId;

  /// Find a playlist by exact name (case-insensitive), paginating through all user playlists.
  Future<String?> findPlaylistByName(String accessToken, String name) async {
    final needle = name.trim();

    // Check cache
    if (DateTime.now().difference(_cacheTimestamp) < _cacheTtl) {
      final cached = _cache[needle.toLowerCase()];
      if (cached != null) return cached;
    } else {
      _cache.clear();
    }

    var offset = 0;
    while (true) {
      final page = await _client.getUserPlaylists(accessToken, offset: offset);
      for (final playlist in page.items) {
        // Populate cache for all results
        _cache[playlist.name.trim().toLowerCase()] = playlist.id;
        _cacheTimestamp = DateTime.now();

        if (playlist.name.trim().toLowerCase() == needle.toLowerCase()) {
          return playlist.id;
        }
      }
      if (page.items.length < 50) break;
      offset += 50;
    }
    return null;
  }

  /// Find playlist by name, or create it if [createIfMissing] is true.
  Future<String?> ensurePlaylist(
    String accessToken,
    String name, {
    bool createIfMissing = true,
  }) async {
    final existing = await findPlaylistByName(accessToken, name);
    if (existing != null) return existing;
    if (!createIfMissing) return null;

    _cache.clear(); // invalidate before creation

    final userId = await ensureUserId(accessToken);
    if (userId == null) return null;

    try {
      final id = await _client.createPlaylist(
        accessToken,
        userId: userId,
        name: name,
      );
      _cache[name.trim().toLowerCase()] = id;
      _cacheTimestamp = DateTime.now();
      return id;
    } catch (e) {
      debugPrint('Failed to create playlist "$name": $e');
      return null;
    }
  }

  Future<void> addTrack(String accessToken, String playlistId, String trackUri) =>
      _client.addTracksToPlaylist(accessToken, playlistId: playlistId, trackUris: [trackUri]);

  Future<bool> removeTrack(String accessToken, String playlistId, String trackUri) async {
    try {
      await _client.removeTracksFromPlaylist(
        accessToken,
        playlistId: playlistId,
        trackUris: [trackUri],
      );
      return true;
    } catch (e) {
      debugPrint('Remove from playlist failed: $e');
      return false;
    }
  }

  /// The signed-in account's Spotify user id, fetched once and kept.
  ///
  /// Not private, because the shared like counter keys its rows by this id and
  /// has to be able to ask for it: while this lived behind playlist creation,
  /// anyone whose rules were off never had one, and every like they made went
  /// to the local count with the shared sheet left empty.
  Future<String?> ensureUserId(String accessToken) async {
    _cachedUserId ??= await _client.getCurrentUserId(accessToken);
    return _cachedUserId;
  }

  /// Force-clear the playlist name → ID cache.
  void invalidateCache() {
    _cache.clear();
    _cacheTimestamp = DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// Forget who is signed in, so the next ask looks the id up again.
  ///
  /// Called when the account can have changed under us — a disconnect, or a
  /// fresh authorization. Both playlists and the shared like counter are keyed
  /// by this id, so keeping a stale one would file a second account's likes
  /// under the first account's name.
  void forgetUserId() {
    _cachedUserId = null;
    invalidateCache();
  }
}
