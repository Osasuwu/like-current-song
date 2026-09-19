import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/entities/app_log.dart';
import '../../domain/entities/like_result.dart';
import '../../domain/entities/pending_like.dart';
import '../../domain/entities/spotify_auth_state.dart';
import '../../domain/entities/track_info.dart';
import '../../domain/repositories/like_count_repository.dart';
import '../../domain/repositories/music_service_repository.dart';
import '../../domain/repositories/platform_service_repository.dart';
import '../../domain/repositories/settings_repository.dart';
import 'spotify_client.dart';
import 'spotify_playlist_service.dart';
import 'spotify_token_store.dart';

class SpotifyMusicServiceRepository implements MusicServiceRepository {
  SpotifyMusicServiceRepository({
    required SpotifyClient spotifyClient,
    required SpotifyTokenStore tokenStore,
    required PlatformServiceRepository platformServiceRepository,
    required LikeCountRepository likeCountRepository,
    required SettingsRepository settingsRepository,
    required String clientId,
    required String redirectUri,
  })  : _spotifyClient = spotifyClient,
        _tokenStore = tokenStore,
        _platformServiceRepository = platformServiceRepository,
        _likeCountRepository = likeCountRepository,
        _settingsRepository = settingsRepository,
        _clientId = clientId,
        _redirectUri = redirectUri,
        _playlistService = SpotifyPlaylistService(spotifyClient);

  final SpotifyClient _spotifyClient;
  final SpotifyTokenStore _tokenStore;
  final PlatformServiceRepository _platformServiceRepository;
  final LikeCountRepository _likeCountRepository;
  final SettingsRepository _settingsRepository;
  final SpotifyPlaylistService _playlistService;
  final String _clientId;
  final String _redirectUri;

  String? _pendingVerifier;
  String? _pendingState;

  // ── Auth ───────────────────────────────────────────────────────

  @override
  Future<SpotifyAuthState> getAuthState() async {
    final state = await _readStoredAuthState();
    if (!_shouldRefresh(state)) return state;

    try {
      return await _refreshAuthState(state);
    } catch (error, stackTrace) {
      debugPrint('Spotify token refresh skipped in getAuthState: $error\n$stackTrace');
      return state;
    }
  }

  Future<SpotifyAuthState> _readStoredAuthState() async {
    final access = await _tokenStore.readAccessToken();
    final refresh = await _tokenStore.readRefreshToken();
    final expiry = await _tokenStore.readExpiryEpochSec();

    if (refresh == null || refresh.isEmpty || expiry == null) {
      return const SpotifyAuthState.disconnected();
    }

    return SpotifyAuthState(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiry * 1000, isUtc: true),
      connected: true,
    );
  }

  bool _shouldRefresh(SpotifyAuthState state) {
    if (!state.connected) return false;
    final access = state.accessToken;
    if (state.isExpired || access == null || access.isEmpty) return true;
    // Proactive refresh: if token expires within 5 minutes
    final expiresAt = state.expiresAt;
    if (expiresAt != null) {
      final remaining = expiresAt.difference(DateTime.now().toUtc());
      if (remaining.inMinutes < 5) return true;
    }
    return false;
  }

  Future<SpotifyAuthState> _refreshAuthState(SpotifyAuthState state) async {
    final refresh = state.refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw Exception('Missing refresh token');
    }

    final refreshed = await _spotifyClient.refreshToken(
      refreshToken: refresh,
      clientId: _clientId,
    );
    final expiresAt = DateTime.now().toUtc().add(Duration(seconds: refreshed.expiresInSec));
    final expiresAtEpochSec = expiresAt.millisecondsSinceEpoch ~/ 1000;

    await _tokenStore.save(
      accessToken: refreshed.accessToken,
      refreshToken: refreshed.refreshToken,
      expiresAtEpochSec: expiresAtEpochSec,
    );

    await _platformServiceRepository.syncSpotifyTokens(
      accessToken: refreshed.accessToken,
      refreshToken: refreshed.refreshToken,
      expiresAtEpochSec: expiresAtEpochSec,
      clientId: _clientId,
    );

    return SpotifyAuthState(
      accessToken: refreshed.accessToken,
      refreshToken: refreshed.refreshToken,
      expiresAt: expiresAt,
      connected: true,
    );
  }

  Future<String> _ensureAccessToken() async {
    await refreshIfNeeded();
    final state = await _readStoredAuthState();
    final token = state.accessToken;
    if (token == null || token.isEmpty) {
      throw Exception('Service is disconnected');
    }
    return token;
  }

  // ── OAuth flow ─────────────────────────────────────────────────

  Future<Uri> beginSpotifyAuthorization() async {
    if (_clientId.isEmpty) {
      throw Exception(
        'Missing SPOTIFY_CLIENT_ID. Pass --dart-define=SPOTIFY_CLIENT_ID=<id>.',
      );
    }
    final verifier = _spotifyClient.createCodeVerifier();
    final challenge = _spotifyClient.codeChallenge(verifier);
    final state = DateTime.now().millisecondsSinceEpoch.toString();
    _pendingVerifier = verifier;
    _pendingState = state;

    return _spotifyClient.buildAuthorizeUri(
      clientId: _clientId,
      redirectUri: _redirectUri,
      codeChallenge: challenge,
      state: state,
    );
  }

  Future<SpotifyAuthState> completeAuthorization(Uri uri) async {
    final state = uri.queryParameters['state'];
    final code = uri.queryParameters['code'];

    if (state == null || code == null) {
      throw Exception('Spotify callback is missing state/code');
    }
    if (_pendingState == null || _pendingVerifier == null || state != _pendingState) {
      throw Exception('Spotify callback state mismatch');
    }

    final token = await _spotifyClient.exchangeCode(
      code: code,
      clientId: _clientId,
      redirectUri: _redirectUri,
      codeVerifier: _pendingVerifier!,
    );

    final expiresAt = DateTime.now().toUtc().add(Duration(seconds: token.expiresInSec));
    await _tokenStore.save(
      accessToken: token.accessToken,
      refreshToken: token.refreshToken,
      expiresAtEpochSec: expiresAt.millisecondsSinceEpoch ~/ 1000,
    );

    await _platformServiceRepository.syncSpotifyTokens(
      accessToken: token.accessToken,
      refreshToken: token.refreshToken,
      expiresAtEpochSec: expiresAt.millisecondsSinceEpoch ~/ 1000,
      clientId: _clientId,
    );

    _pendingState = null;
    _pendingVerifier = null;

    return SpotifyAuthState(
      accessToken: token.accessToken,
      refreshToken: token.refreshToken,
      expiresAt: expiresAt,
      connected: true,
    );
  }

  @override
  Future<SpotifyAuthState> connect() async {
    final authorizeUri = await beginSpotifyAuthorization();
    await _spotifyClient.launchAuthPage(authorizeUri);
    return getAuthState();
  }

  @override
  Future<void> disconnect() async {
    await _tokenStore.clear();
  }

  @override
  Future<void> refreshIfNeeded() async {
    final state = await _readStoredAuthState();
    if (!_shouldRefresh(state)) return;
    await _refreshAuthState(state);
  }

  @override
  Future<bool> handleAuthCallback(Uri uri) async {
    if (!uri.toString().startsWith(_redirectUri)) return false;
    try {
      await completeAuthorization(uri);
      return true;
    } catch (error, stackTrace) {
      debugPrint('Spotify callback failed: $error\n$stackTrace');
      rethrow;
    }
  }

  // ── Full like workflow ─────────────────────────────────────────

  @override
  Future<LikeResult> likeCurrentTrack() async {
    var accessToken = await _ensureAccessToken();

    // 1. Get current track info (with 401 retry)
    TrackInfo? trackInfo;
    try {
      trackInfo = await _spotifyClient.getCurrentlyPlayingFull(accessToken);
    } on SpotifyAuthException {
      await refreshIfNeeded();
      accessToken = await _ensureAccessToken();
      trackInfo = await _spotifyClient.getCurrentlyPlayingFull(accessToken);
    }

    if (trackInfo == null) {
      throw Exception('No track is currently playing');
    }

    return likeTrack(trackInfo);
  }

  @override
  Future<LikeResult> likeTrack(TrackInfo trackInfo) async {
    final accessToken = await _ensureAccessToken();
    final ruleConfig = await _settingsRepository.loadRuleConfig();

    // 0. Skip if this track was liked within the cooldown window
    if (ruleConfig.likeCooldownEnabled && ruleConfig.likeCooldownMinutes > 0) {
      final lastLikedAt = await _likeCountRepository.getLastLikedAt(trackInfo.trackId);
      if (lastLikedAt != null &&
          DateTime.now().toUtc().difference(lastLikedAt) <
              Duration(minutes: ruleConfig.likeCooldownMinutes)) {
        return LikeResult(
          trackId: trackInfo.trackId,
          trackName: trackInfo.trackName,
          trackLiked: false,
          skippedCooldown: true,
          trackLikeCount: await _likeCountRepository.getTrackLikeCount(trackInfo.trackId),
        );
      }
    }

    // 1. Like the track
    await _spotifyClient.likeTrack(trackId: trackInfo.trackId, accessToken: accessToken);
    await _likeCountRepository.recordLikedAt(trackInfo.trackId, DateTime.now().toUtc());

    // 3. Remove from archive playlist (non-blocking)
    var removedFromArchive = false;
    if (ruleConfig.archiveRemoveEnabled && ruleConfig.archivePlaylistName.isNotEmpty) {
      try {
        final archiveId = await _playlistService.findPlaylistByName(
          accessToken,
          ruleConfig.archivePlaylistName,
        );
        if (archiveId != null) {
          removedFromArchive = await _playlistService.removeTrack(
            accessToken,
            archiveId,
            trackInfo.trackUri,
          );
        }
      } catch (e) {
        debugPrint('Archive removal failed: $e');
        await _settingsRepository.appendLog(AppLog(
          at: DateTime.now().toUtc(),
          actionType: 'archive_remove',
          targetId: trackInfo.trackId,
          result: LogResult.failure,
          httpCode: e is SpotifyApiException ? e.statusCode : null,
          message: 'Archive removal failed: $e',
        ));
      }
    }

    // 4. Increment like count (always, regardless of best-of rule state)
    final trackLikeCount = await _likeCountRepository.incrementTrackLikeCount(trackInfo.trackId);

    // 5. Add to best-of playlist at configured threshold
    var addedToBestOf = false;
    if (ruleConfig.bestOfEnabled &&
        trackLikeCount == ruleConfig.bestOfThreshold &&
        ruleConfig.bestOfPlaylistName.isNotEmpty) {
      try {
        final bestOfId = await _playlistService.ensurePlaylist(accessToken, ruleConfig.bestOfPlaylistName);
        if (bestOfId != null) {
          await _playlistService.addTrack(accessToken, bestOfId, trackInfo.trackUri);
          addedToBestOf = true;
        }
      } catch (e) {
        debugPrint('Best-of add failed: $e');
        await _settingsRepository.appendLog(AppLog(
          at: DateTime.now().toUtc(),
          actionType: 'best_of_add',
          targetId: trackInfo.trackId,
          result: LogResult.failure,
          httpCode: e is SpotifyApiException ? e.statusCode : null,
          message: 'Best-of add failed: $e',
        ));
      }
    }

    // 6. Increment artist like counts (always) and auto-follow at configured threshold
    final followedArtistNames = <String>[];
    for (var i = 0; i < trackInfo.artistIds.length; i++) {
      final artistId = trackInfo.artistIds[i];
      final artistCount = await _likeCountRepository.incrementArtistLikeCount(artistId);
      if (ruleConfig.followArtistEnabled && artistCount == ruleConfig.followArtistThreshold) {
        try {
          await _spotifyClient.followArtists(accessToken, artistIds: [artistId]);
          final name = i < trackInfo.artistNames.length ? trackInfo.artistNames[i] : artistId;
          followedArtistNames.add(name);
        } catch (e) {
          debugPrint('Artist follow failed for $artistId: $e');
          await _settingsRepository.appendLog(AppLog(
            at: DateTime.now().toUtc(),
            actionType: 'follow_artist',
            targetId: artistId,
            result: LogResult.failure,
            httpCode: e is SpotifyApiException ? e.statusCode : null,
            message: 'Artist follow failed for $artistId: $e',
          ));
        }
      }
    }

    return LikeResult(
      trackId: trackInfo.trackId,
      trackName: trackInfo.trackName,
      trackLiked: true,
      removedFromArchive: removedFromArchive,
      addedToBestOf: addedToBestOf,
      followedArtistNames: followedArtistNames,
      trackLikeCount: trackLikeCount,
    );
  }

  @override
  Future<int> processPendingLikes(List<PendingLike> pending) async {
    var processed = 0;
    for (final like in pending) {
      try {
        final trackInfo = TrackInfo(
          trackId: like.trackId,
          trackName: like.trackName,
          artistIds: like.artistIds,
          artistNames: like.artistNames,
        );
        await likeTrack(trackInfo);
        await _settingsRepository.removePendingLike(like.trackId);
        processed++;
      } catch (e) {
        debugPrint('Pending like retry failed for ${like.trackId}: $e');
        break; // Stop on first failure — likely still offline
      }
    }
    return processed;
  }

  @override
  Future<Map<String, Map<String, int>>> loadAllLikeCounts() async {
    return <String, Map<String, int>>{
      'tracks': await _likeCountRepository.loadAllTrackLikeCounts(),
      'artists': await _likeCountRepository.loadAllArtistLikeCounts(),
    };
  }

  /// Expose playlist service's cached user ID for Supabase like counting.
  String? get cachedUserId => _playlistService.cachedUserId;
}
