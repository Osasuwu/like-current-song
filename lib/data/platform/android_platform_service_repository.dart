import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/app_constants.dart';
import '../../domain/entities/app_log.dart';
import '../../domain/entities/music_provider.dart';
import '../../domain/entities/music_routing.dart';
import '../../domain/entities/rule_config.dart';
import '../../domain/entities/trigger_config.dart';
import '../../domain/repositories/platform_service_repository.dart';

class AndroidPlatformServiceRepository implements PlatformServiceRepository {
  final MethodChannel _methodChannel =
      const MethodChannel(AppConstants.serviceMethodChannel);
  final EventChannel _eventChannel =
      const EventChannel(AppConstants.serviceEventChannel);

  @override
  Future<void> startForegroundListener() async {
    await _methodChannel.invokeMethod<void>('startService');
  }

  @override
  Future<void> stopForegroundListener() async {
    await _methodChannel.invokeMethod<void>('stopService');
  }

  @override
  Future<bool> isServiceEnabled() async {
    final enabled = await _methodChannel.invokeMethod<bool>('isServiceEnabled');
    return enabled ?? false;
  }

  @override
  Future<void> updateTriggerConfig(TriggerConfig config) async {
    await _methodChannel.invokeMethod<void>('setTriggerConfig', <String, dynamic>{
      'pattern': config.pattern,
      'windowMs': config.windowMs,
      'debounceMs': config.debounceMs,
      'feedbackVolume': config.feedbackVolume,
    });
  }

  @override
  Future<bool> isIgnoringBatteryOptimizations() async {
    final result = await _methodChannel
        .invokeMethod<bool>('isIgnoringBatteryOptimizations');
    return result ?? false;
  }

  @override
  Future<void> openIgnoreBatteryOptimizationSettings() async {
    await _methodChannel
        .invokeMethod<void>('openIgnoreBatteryOptimizationsSettings');
  }

  @override
  Future<void> openBatteryOptimizationSettings() async {
    await _methodChannel.invokeMethod<void>('openBatteryOptimizationSettings');
  }

  @override
  Future<void> openNotificationSettings() async {
    await _methodChannel.invokeMethod<void>('openNotificationSettings');
  }

  @override
  Future<bool> isNotificationListenerEnabled() async {
    final result =
        await _methodChannel.invokeMethod<bool>('isNotificationListenerEnabled');
    return result ?? false;
  }

  @override
  Future<void> openNotificationListenerSettings() async {
    await _methodChannel.invokeMethod<void>('openNotificationListenerSettings');
  }

  @override
  Future<bool> isMiuiDevice() async {
    final result = await _methodChannel.invokeMethod<bool>('isMiuiDevice');
    return result ?? false;
  }

  @override
  Future<void> openMiuiAutostartSettings() async {
    await _methodChannel.invokeMethod<void>('openMiuiAutostartSettings');
  }

  @override
  Future<bool> isMusicAppInstalled(MusicProvider provider) async {
    final result = await _methodChannel.invokeMethod<bool>(
      'isMusicAppInstalled',
      <String, dynamic>{'provider': provider.id},
    );
    return result ?? false;
  }

  @override
  Future<bool> openMusicApp(MusicProvider provider) async {
    final result = await _methodChannel.invokeMethod<bool>(
      'openMusicApp',
      <String, dynamic>{'provider': provider.id},
    );
    return result ?? false;
  }

  @override
  Future<void> updateMusicProvider(MusicProvider provider) async {
    await _methodChannel.invokeMethod<void>(
      'setMusicProvider',
      <String, dynamic>{'provider': provider.id},
    );
  }

  @override
  Future<void> updateMusicRoutingMode(MusicRoutingMode mode) async {
    await _methodChannel.invokeMethod<void>(
      'setMusicRoutingMode',
      <String, dynamic>{'mode': mode.id},
    );
  }

  @override
  Future<MusicSessionSnapshot> readMusicSessions() async {
    final result =
        await _methodChannel.invokeMapMethod<String, dynamic>('getMusicSessions');
    if (result == null) return const MusicSessionSnapshot();
    return MusicSessionSnapshot.fromChannel(result);
  }

  @override
  Future<void> updateRuleConfig(RuleConfig config) async {
    await _methodChannel.invokeMethod<void>('setRuleConfig', config.toJson());
  }

  @override
  Future<List<AppLog>> drainBackgroundLogs() async {
    final List<dynamic>? entries;
    try {
      entries = await _methodChannel.invokeMethod<List<dynamic>>(
        'drainBackgroundLogs',
      );
    } on PlatformException {
      // A device running an older native half has no such method, and a
      // channel failure here is not worth breaking start-up over: the Logs
      // screen simply misses the background stretch, as it did before.
      return const <AppLog>[];
    } on MissingPluginException {
      return const <AppLog>[];
    }
    if (entries == null) return const <AppLog>[];

    final logs = <AppLog>[];
    for (final entry in entries) {
      if (entry is! Map) continue;
      final atMs = entry['atMs'];
      final message = entry['message'];
      // Without a timestamp the line cannot be placed on the Logs screen, so
      // one bad entry is dropped rather than taking the whole batch with it.
      if (atMs is! int || message is! String) continue;
      final actionType = entry['actionType'];
      final targetId = entry['targetId'];
      final result = entry['result'];
      final httpCode = entry['httpCode'];
      logs.add(AppLog(
        at: DateTime.fromMillisecondsSinceEpoch(atMs, isUtc: true),
        actionType: actionType is String ? actionType : 'legacy',
        targetId: targetId is String ? targetId : null,
        result: LogResult.fromName(result is String ? result : null),
        httpCode: httpCode is int ? httpCode : null,
        message: message,
      ));
    }
    return logs;
  }

  @override
  Future<Set<String>> loadFollowedArtists() async {
    final ids = await _methodChannel.invokeMethod<List<dynamic>>(
      'loadFollowedArtists',
    );
    if (ids == null) return const <String>{};
    return ids.whereType<String>().toSet();
  }

  @override
  Future<void> markArtistFollowed(String artistId) async {
    await _methodChannel.invokeMethod<void>(
      'markArtistFollowed',
      <String, dynamic>{'id': artistId},
    );
  }

  @override
  Stream<Map<String, dynamic>> events() {
    return _eventChannel
        .receiveBroadcastStream()
        .where((event) => event is Map)
        .map((event) => Map<String, dynamic>.from(event as Map));
  }

  @override
  Future<void> syncSpotifyTokens({
    required String accessToken,
    required String refreshToken,
    required int expiresAtEpochSec,
    required String clientId,
  }) async {
    await _methodChannel.invokeMethod<void>('syncSpotifyTokens', <String, dynamic>{
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'expiresAtEpochSec': expiresAtEpochSec,
      'clientId': clientId,
    });
  }

  @override
  Future<void> clearSpotifyUserId() async {
    await _methodChannel.invokeMethod<void>('clearSpotifyUserId');
  }

  @override
  Future<void> syncYouTubeMusicTokens({
    required String accessToken,
    required String refreshToken,
    required int expiresAtEpochMs,
    required String clientId,
    required String clientSecret,
    String? userSub,
  }) async {
    await _methodChannel
        .invokeMethod<void>('syncYouTubeMusicTokens', <String, dynamic>{
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'expiresAtEpochMs': expiresAtEpochMs,
      'clientId': clientId,
      'clientSecret': clientSecret,
      'userSub': userSub,
    });
  }

  @override
  Future<void> clearYouTubeMusicTokens() async {
    await _methodChannel.invokeMethod<void>('clearYouTubeMusicTokens');
  }

  @override
  Future<void> syncLikeCounterConfig({
    required String spreadsheetId,
    required String clientId,
    required String clientSecret,
    required String accessToken,
    required String refreshToken,
    required int expiresAtEpochMs,
  }) async {
    await _methodChannel
        .invokeMethod<void>('setLikeCounterConfig', <String, dynamic>{
      'spreadsheetId': spreadsheetId,
      'clientId': clientId,
      'clientSecret': clientSecret,
      'accessToken': accessToken,
      'refreshToken': refreshToken,
      'expiresAtEpochMs': expiresAtEpochMs,
    });
  }

  @override
  Future<void> playFeedbackTone({required bool success}) async {
    await _methodChannel.invokeMethod<void>('playFeedbackTone', <String, dynamic>{
      'success': success,
    });
  }

  @override
  Future<Map<String, dynamic>> likeYouTubeMusicCurrentTrack() async {
    final result =
        await _methodChannel.invokeMapMethod<String, dynamic>('likeYouTubeMusic');
    return result ?? const <String, dynamic>{'outcome': 'failed'};
  }
}
