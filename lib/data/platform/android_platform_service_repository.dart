import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/app_constants.dart';
import '../../domain/entities/music_provider.dart';
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
  Future<void> updateRuleConfig(RuleConfig config) async {
    await _methodChannel.invokeMethod<void>('setRuleConfig', config.toJson());
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
  Future<void> syncSupabaseConfig({
    required String supabaseUrl,
    required String supabaseAnonKey,
  }) async {
    await _methodChannel.invokeMethod<void>('setSupabaseConfig', <String, dynamic>{
      'supabaseUrl': supabaseUrl,
      'supabaseAnonKey': supabaseAnonKey,
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
