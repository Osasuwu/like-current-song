import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/app_constants.dart';
import '../../domain/entities/app_log.dart';
import '../../domain/entities/like_destination.dart';
import '../../domain/entities/like_result.dart';
import '../../domain/entities/pending_like.dart';
import '../../domain/entities/rule_config.dart';
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
  })  : _spotifyClient = spotifyClient,
        _tokenStore = tokenStore,
        _platformServiceRepository = platformServiceRepository,
        _likeCountRepository = likeCountRepository,
        _settingsRepository = settingsRepository,
        _playlistService = SpotifyPlaylistService(spotifyClient);

  /// What to do about a missing client ID, in the words of the screen that
  /// takes it. Shown wherever the OAuth flow needs one and finds none.
  static const missingClientIdMessage =
      'Add your Spotify client ID in Connected services.';

  final SpotifyClient _spotifyClient;
  final SpotifyTokenStore _tokenStore;
  final PlatformServiceRepository _platformServiceRepository;
  final LikeCountRepository _likeCountRepository;
  final SettingsRepository _settingsRepository;
  final SpotifyPlaylistService _playlistService;

  String? _pendingVerifier;
  String? _pendingState;

  /// The user's client ID, read at call time: it is entered in the app, so a
  /// value held at construction would be the one from before they typed it.
  Future<String> _readClientId() async =>
      (await _tokenStore.readClientId())?.trim() ?? '';

  Future<String> _requireClientId() async {
    final clientId = await _readClientId();
    if (clientId.isEmpty) throw Exception(missingClientIdMessage);
    return clientId;
  }

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

    final clientId = await _requireClientId();
    final refreshed = await _spotifyClient.refreshToken(
      refreshToken: refresh,
      clientId: clientId,
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
      clientId: clientId,
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
    final clientId = await _requireClientId();
    final verifier = _spotifyClient.createCodeVerifier();
    final challenge = _spotifyClient.codeChallenge(verifier);
    final state = DateTime.now().millisecondsSinceEpoch.toString();
    _pendingVerifier = verifier;
    _pendingState = state;

    return _spotifyClient.buildAuthorizeUri(
      clientId: clientId,
      redirectUri: AppConstants.spotifyRedirectUri,
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

    final clientId = await _requireClientId();
    final token = await _spotifyClient.exchangeCode(
      code: code,
      clientId: clientId,
      redirectUri: AppConstants.spotifyRedirectUri,
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
      clientId: clientId,
    );
    // Whoever just signed in may not be who signed in last, and the user id
    // both halves cache keys the shared like counter's rows.
    await _forgetUserId();

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
    await _forgetUserId();
  }

  /// Drops the cached Spotify user id on both sides of the method channel.
  ///
  /// The native side keeps it in `SharedPreferences` with no expiry, so
  /// nothing but this ever clears it; leaving it behind after an account
  /// change would file the new account's likes under the old account's row in
  /// the shared counter. A native side that cannot do it is not worth failing
  /// a disconnect over — the in-process copy is still dropped.
  Future<void> _forgetUserId() async {
    _playlistService.forgetUserId();
    try {
      await _platformServiceRepository.clearSpotifyUserId();
    } catch (error) {
      debugPrint('Could not clear the cached Spotify user id: $error');
    }
  }

  @override
  Future<void> refreshIfNeeded() async {
    final state = await _readStoredAuthState();
    if (!_shouldRefresh(state)) return;
    await _refreshAuthState(state);
  }

  @override
  Future<bool> handleAuthCallback(Uri uri) async {
    if (!uri.toString().startsWith(AppConstants.spotifyRedirectUri)) {
      return false;
    }
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

    // 1. Like the track, wherever the user wants likes to go
    final legs = await _runLikeLegs(trackInfo, accessToken, ruleConfig);
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

    // 4. Increment like count (always, regardless of best rule state)
    final trackLikeCount = await _likeCountRepository.incrementTrackLikeCount(trackInfo.trackId);

    // 5. Add to best playlist at configured threshold
    var addedToBest = false;
    if (ruleConfig.bestEnabled &&
        trackLikeCount == ruleConfig.bestThreshold &&
        ruleConfig.bestPlaylistName.isNotEmpty) {
      try {
        final bestId = await _playlistService.ensurePlaylist(accessToken, ruleConfig.bestPlaylistName);
        if (bestId != null) {
          await _playlistService.addTrack(accessToken, bestId, trackInfo.trackUri);
          addedToBest = true;
        }
      } catch (e) {
        debugPrint('Best add failed: $e');
        await _settingsRepository.appendLog(AppLog(
          at: DateTime.now().toUtc(),
          actionType: 'best_add',
          targetId: trackInfo.trackId,
          result: LogResult.failure,
          httpCode: e is SpotifyApiException ? e.statusCode : null,
          message: 'Best add failed: $e',
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
      addedToBest: addedToBest,
      followedArtistNames: followedArtistNames,
      trackLikeCount: trackLikeCount,
      likedNatively: legs.likedNatively,
      addedToLikePlaylist: legs.addedToLikePlaylist,
      partialFailureMessage: legs.partialFailureMessage,
    );
  }

  /// Sends the like itself, on whichever legs the destination asks for.
  ///
  /// A one-leg destination lets a failure propagate: the like did not happen,
  /// and the caller has to know — an offline retry queue depends on it. With
  /// `both`, one leg is enough for the song to end up liked, so the like only
  /// fails when both legs do; a half failure is reported back on
  /// [LikeResult.partialFailureMessage] for the caller to log.
  Future<_LikeLegs> _runLikeLegs(
    TrackInfo trackInfo,
    String accessToken,
    RuleConfig ruleConfig,
  ) async {
    final playlistName = ruleConfig.likePlaylistName.trim();
    final destination = LikeDestination.resolve(ruleConfig.likeDestination, playlistName);

    if (!destination.addsToPlaylist) {
      await _spotifyClient.likeTrack(trackId: trackInfo.trackId, accessToken: accessToken);
      return const _LikeLegs(likedNatively: true);
    }
    if (!destination.likesNatively) {
      await _addToLikePlaylist(trackInfo, accessToken, playlistName);
      return const _LikeLegs(addedToLikePlaylist: true);
    }

    Object? nativeError;
    try {
      await _spotifyClient.likeTrack(trackId: trackInfo.trackId, accessToken: accessToken);
    } catch (e) {
      debugPrint('Like to liked songs failed: $e');
      nativeError = e;
    }

    Object? playlistError;
    try {
      await _addToLikePlaylist(trackInfo, accessToken, playlistName);
    } catch (e) {
      debugPrint('Like to playlist failed: $e');
      playlistError = e;
    }

    if (nativeError != null && playlistError != null) {
      // Nothing worked. Rethrow the liked-songs error: it is the leg with an
      // HTTP status the caller can log and act on.
      throw nativeError;
    }
    return _LikeLegs(
      likedNatively: nativeError == null,
      addedToLikePlaylist: playlistError == null,
      partialFailureMessage: nativeError != null
          ? 'Liked songs failed, so the like only reached "$playlistName": $nativeError'
          : playlistError != null
              ? 'Adding to "$playlistName" failed, so the like only reached liked songs: $playlistError'
              : null,
    );
  }

  /// Adds the track to the user's like playlist, creating it if it is missing.
  Future<void> _addToLikePlaylist(
    TrackInfo trackInfo,
    String accessToken,
    String playlistName,
  ) async {
    final playlistId = await _playlistService.ensurePlaylist(accessToken, playlistName);
    if (playlistId == null) {
      throw Exception('Could not find or create the playlist "$playlistName"');
    }
    await _playlistService.addTrack(accessToken, playlistId, trackInfo.trackUri);
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

  /// The signed-in account's Spotify user id, which keys the shared like
  /// counter's rows. Fetched on first ask and kept afterwards.
  ///
  /// Null when nobody is signed in, or when the lookup failed — the counter
  /// treats that as "count locally for now" rather than an error, so the
  /// failure must not propagate.
  Future<String?> ensureUserId() async {
    try {
      return await _playlistService.ensureUserId(await _ensureAccessToken());
    } catch (error) {
      debugPrint('Spotify user id unavailable for the like counter: $error');
      return null;
    }
  }
}

/// Which halves of a like actually went through, and what to say when one of
/// them did not.
class _LikeLegs {
  const _LikeLegs({
    this.likedNatively = false,
    this.addedToLikePlaylist = false,
    this.partialFailureMessage,
  });

  final bool likedNatively;
  final bool addedToLikePlaylist;
  final String? partialFailureMessage;
}
