import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_constants.dart';
import '../../domain/entities/music_service_exceptions.dart';
import '../../domain/entities/track_info.dart';
import 'spotify_models.dart';

class SpotifyClient {
  final http.Client _http;
  static const _timeout = Duration(seconds: 10);

  SpotifyClient(this._http);

  String createCodeVerifier({int length = 64}) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return List<String>.generate(
      length,
      (_) => chars[random.nextInt(chars.length)],
      growable: false,
    ).join();
  }

  String codeChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  Uri buildAuthorizeUri({
    required String clientId,
    required String redirectUri,
    required String codeChallenge,
    required String state,
  }) {
    return Uri.parse(AppConstants.spotifyAuthorizeUrl).replace(
      queryParameters: <String, String>{
        'client_id': clientId,
        'response_type': 'code',
        'redirect_uri': redirectUri,
        'code_challenge_method': 'S256',
        'code_challenge': codeChallenge,
        'state': state,
        'scope':
            'user-library-modify user-library-read user-read-playback-state user-follow-modify playlist-read-private playlist-read-collaborative playlist-modify-private playlist-modify-public',
      },
    );
  }

  Future<void> launchAuthPage(Uri uri) async {
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      throw Exception('Failed to open Spotify authentication page');
    }
  }

  Future<SpotifyTokenResponse> exchangeCode({
    required String code,
    required String clientId,
    required String redirectUri,
    required String codeVerifier,
  }) async {
    final response = await _http.post(
      Uri.parse(AppConstants.spotifyTokenUrl),
      headers: <String, String>{
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: <String, String>{
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirectUri,
        'client_id': clientId,
        'code_verifier': codeVerifier,
      },
    ).timeout(_timeout);

    if (response.statusCode < 200 || response.statusCode > 299) {
      throw SpotifyApiException(response.statusCode, 'Spotify token exchange failed');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return SpotifyTokenResponse(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String? ?? '',
      expiresInSec: json['expires_in'] as int,
    );
  }

  Future<SpotifyTokenResponse> refreshToken({
    required String refreshToken,
    required String clientId,
  }) async {
    final response = await _http.post(
      Uri.parse(AppConstants.spotifyTokenUrl),
      headers: <String, String>{
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: <String, String>{
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': clientId,
      },
    ).timeout(_timeout);

    if (response.statusCode < 200 || response.statusCode > 299) {
      throw SpotifyApiException(response.statusCode, 'Spotify token refresh failed');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return SpotifyTokenResponse(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String? ?? refreshToken,
      expiresInSec: json['expires_in'] as int,
    );
  }

  Future<String?> currentTrackId(String accessToken) async {
    final response = await _http.get(
      Uri.parse('${AppConstants.spotifyApiBase}/me/player/currently-playing'),
      headers: <String, String>{'Authorization': 'Bearer $accessToken'},
    ).timeout(_timeout);

    if (response.statusCode == 204) {
      return null;
    }

    if (response.statusCode < 200 || response.statusCode > 299) {
      throw SpotifyApiException(
        response.statusCode,
        'Spotify current track failed: ${response.body}',
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final item = json['item'] as Map<String, dynamic>?;
    return item?['id'] as String?;
  }

  Future<void> likeTrack({
    required String trackId,
    required String accessToken,
  }) async {
    final response = await _http.put(
      Uri.parse('${AppConstants.spotifyApiBase}/me/tracks?ids=$trackId'),
      headers: <String, String>{'Authorization': 'Bearer $accessToken'},
    ).timeout(_timeout);

    if (response.statusCode < 200 || response.statusCode > 299) {
      throw SpotifyApiException(response.statusCode, 'Spotify like track failed');
    }
  }

  /// Returns full track info (id, name, artists) for the currently playing track.
  Future<TrackInfo?> getCurrentlyPlayingFull(String accessToken) async {
    final response = await _http.get(
      Uri.parse('${AppConstants.spotifyApiBase}/me/player/currently-playing'),
      headers: <String, String>{'Authorization': 'Bearer $accessToken'},
    ).timeout(_timeout);

    if (response.statusCode == 204) return null;

    if (response.statusCode == 401) {
      throw SpotifyAuthException('Token expired');
    }

    if (response.statusCode < 200 || response.statusCode > 299) {
      throw SpotifyApiException(response.statusCode, 'Spotify current track failed');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final item = json['item'] as Map<String, dynamic>?;
    if (item == null) return null;

    final id = item['id'] as String?;
    if (id == null || id.isEmpty) return null;

    final name = item['name'] as String? ?? '';
    final artists = item['artists'] as List<dynamic>? ?? <dynamic>[];
    final artistIds = <String>[];
    final artistNames = <String>[];
    for (final artist in artists) {
      final a = artist as Map<String, dynamic>;
      final aid = a['id'] as String?;
      if (aid != null && aid.isNotEmpty) {
        artistIds.add(aid);
        artistNames.add(a['name'] as String? ?? '');
      }
    }

    return TrackInfo(
      trackId: id,
      trackName: name,
      artistIds: artistIds,
      artistNames: artistNames,
    );
  }

  /// GET /me — returns the current user's Spotify ID.
  Future<String?> getCurrentUserId(String accessToken) async {
    final response = await _http.get(
      Uri.parse('${AppConstants.spotifyApiBase}/me'),
      headers: <String, String>{'Authorization': 'Bearer $accessToken'},
    ).timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode > 299) return null;
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final id = json['id'] as String?;
    return (id != null && id.isNotEmpty) ? id : null;
  }

  /// GET /me/playlists — paginated.
  Future<SpotifyPlaylistPage> getUserPlaylists(
    String accessToken, {
    int offset = 0,
    int limit = 50,
  }) async {
    final response = await _http.get(
      Uri.parse('${AppConstants.spotifyApiBase}/me/playlists?limit=$limit&offset=$offset'),
      headers: <String, String>{'Authorization': 'Bearer $accessToken'},
    ).timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw SpotifyApiException(response.statusCode, 'Spotify get playlists failed');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final items = json['items'] as List<dynamic>? ?? <dynamic>[];
    final total = json['total'] as int? ?? 0;
    return SpotifyPlaylistPage(
      items: items.map((e) {
        final p = e as Map<String, dynamic>;
        return SpotifyPlaylistItem(
          id: p['id'] as String? ?? '',
          name: p['name'] as String? ?? '',
        );
      }).toList(growable: false),
      total: total,
    );
  }

  /// POST /users/{userId}/playlists — create a new playlist, returns its ID.
  Future<String> createPlaylist(
    String accessToken, {
    required String userId,
    required String name,
    bool public = false,
    String description = 'Managed by Like Spotify Mobile App',
  }) async {
    final response = await _http.post(
      Uri.parse('${AppConstants.spotifyApiBase}/users/$userId/playlists'),
      headers: <String, String>{
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{
        'name': name,
        'public': public,
        'description': description,
      }),
    ).timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw SpotifyApiException(response.statusCode, 'Spotify create playlist failed');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return json['id'] as String;
  }

  /// POST /playlists/{playlistId}/tracks — add tracks by URI.
  Future<void> addTracksToPlaylist(
    String accessToken, {
    required String playlistId,
    required List<String> trackUris,
  }) async {
    final response = await _http.post(
      Uri.parse('${AppConstants.spotifyApiBase}/playlists/$playlistId/tracks'),
      headers: <String, String>{
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(<String, dynamic>{'uris': trackUris}),
    ).timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw SpotifyApiException(response.statusCode, 'Spotify add to playlist failed');
    }
  }

  /// DELETE /playlists/{playlistId}/tracks — remove tracks by URI.
  Future<void> removeTracksFromPlaylist(
    String accessToken, {
    required String playlistId,
    required List<String> trackUris,
  }) async {
    final request = http.Request(
      'DELETE',
      Uri.parse('${AppConstants.spotifyApiBase}/playlists/$playlistId/tracks'),
    );
    request.headers['Authorization'] = 'Bearer $accessToken';
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode(<String, dynamic>{
      'tracks': trackUris.map((uri) => <String, String>{'uri': uri}).toList(),
    });

    final streamed = await _http.send(request).timeout(_timeout);
    if (streamed.statusCode < 200 || streamed.statusCode > 299) {
      throw SpotifyApiException(streamed.statusCode, 'Spotify remove from playlist failed');
    }
  }

  /// PUT /me/following?type=artist — follow artists.
  Future<void> followArtists(
    String accessToken, {
    required List<String> artistIds,
  }) async {
    final response = await _http.put(
      Uri.parse(
        '${AppConstants.spotifyApiBase}/me/following?type=artist&ids=${artistIds.join(",")}',
      ),
      headers: <String, String>{'Authorization': 'Bearer $accessToken'},
    ).timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw SpotifyApiException(response.statusCode, 'Spotify follow artists failed');
    }
  }

  /// GET /me/tracks — paginated saved (liked) tracks.
  Future<SpotifySavedTrackPage> getSavedTracks(
    String accessToken, {
    int offset = 0,
    int limit = 50,
  }) async {
    final response = await _http.get(
      Uri.parse('${AppConstants.spotifyApiBase}/me/tracks?limit=$limit&offset=$offset'),
      headers: <String, String>{'Authorization': 'Bearer $accessToken'},
    ).timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode > 299) {
      throw SpotifyApiException(response.statusCode, 'Spotify get saved tracks failed');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final items = json['items'] as List<dynamic>? ?? <dynamic>[];
    final total = json['total'] as int? ?? 0;
    return SpotifySavedTrackPage(
      items: items.map((e) {
        final saved = e as Map<String, dynamic>;
        final track = saved['track'] as Map<String, dynamic>;
        final artists = track['artists'] as List<dynamic>? ?? <dynamic>[];
        return SpotifySavedTrack(
          id: track['id'] as String? ?? '',
          name: track['name'] as String? ?? '',
          uri: track['uri'] as String? ?? '',
          artists: artists.map((a) {
            final artist = a as Map<String, dynamic>;
            return SpotifySavedTrackArtist(
              id: artist['id'] as String? ?? '',
              name: artist['name'] as String? ?? '',
            );
          }).toList(growable: false),
        );
      }).toList(growable: false),
      total: total,
    );
  }
}

/// Thrown when a Spotify API call returns a non-2xx response, carrying the
/// real HTTP status code so callers/logs can surface it instead of just the
/// message text.
class SpotifyApiException implements MusicServiceHttpException {
  @override
  final int statusCode;
  final String message;
  SpotifyApiException(this.statusCode, this.message);
  @override
  String toString() => 'SpotifyApiException($statusCode): $message';
}

/// Thrown when Spotify returns 401, signaling the caller should refresh and retry.
class SpotifyAuthException extends SpotifyApiException {
  SpotifyAuthException(String message) : super(401, message);
  @override
  String toString() => 'SpotifyAuthException: $message';
}
