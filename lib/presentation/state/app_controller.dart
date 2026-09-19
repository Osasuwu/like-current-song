import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_constants.dart';
import '../../domain/entities/app_log.dart';
import '../../domain/entities/music_provider.dart';
import '../../domain/entities/music_service_exceptions.dart';
import '../../domain/entities/pending_like.dart';
import '../../domain/entities/rule_config.dart';
import '../../domain/entities/spotify_auth_state.dart';
import '../../domain/entities/track_info.dart';
import '../../domain/entities/trigger_config.dart';
import '../../domain/repositories/music_service_repository.dart';
import '../../domain/repositories/platform_service_repository.dart';
import '../../domain/repositories/settings_repository.dart';
import 'app_state.dart';

class AppController extends StateNotifier<AppState> {
  AppController({
    required SettingsRepository settingsRepository,
    required PlatformServiceRepository platformServiceRepository,
    required MusicServiceRepository musicServiceRepository,
    required AppLinks appLinks,
    this.supabaseUrl = '',
    this.supabaseAnonKey = '',
  })  : _settingsRepository = settingsRepository,
        _platformServiceRepository = platformServiceRepository,
        _musicServiceRepository = musicServiceRepository,
        _appLinks = appLinks,
        super(
          AppState.initial(
            const TriggerConfig(
              pattern: AppConstants.defaultPattern,
              windowMs: AppConstants.defaultWindowMs,
              debounceMs: AppConstants.defaultDebounceMs,
              feedbackVolume: AppConstants.defaultFeedbackVolume,
            ),
          ),
        ) {
    _initialize();
  }

  final SettingsRepository _settingsRepository;
  final PlatformServiceRepository _platformServiceRepository;
  final MusicServiceRepository _musicServiceRepository;
  final AppLinks _appLinks;
  final String supabaseUrl;
  final String supabaseAnonKey;

  StreamSubscription<Map<String, dynamic>>? _nativeEventsSub;
  StreamSubscription<Uri>? _linkSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  Future<void> _initialize() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final config = await _settingsRepository.loadTriggerConfig();
      final musicProvider = await _settingsRepository.loadMusicProvider();
      final serviceEnabled = await _platformServiceRepository.isServiceEnabled();
      final auth = await _musicServiceRepository.getAuthState();
      final ruleConfig = await _settingsRepository.loadRuleConfig();
      final batteryIgnored =
          await _platformServiceRepository.isIgnoringBatteryOptimizations();
        final notificationListenerEnabled =
          await _platformServiceRepository.isNotificationListenerEnabled();
      final isMiui = await _platformServiceRepository.isMiuiDevice();
      final musicAppInstalled =
          await _platformServiceRepository.isMusicAppInstalled(musicProvider);
      final logLines = await _settingsRepository.loadLogs();

      await _platformServiceRepository.updateMusicProvider(musicProvider);
      await _platformServiceRepository.updateTriggerConfig(config);
      await _platformServiceRepository.updateRuleConfig(ruleConfig);
      await _platformServiceRepository.syncSupabaseConfig(
        supabaseUrl: supabaseUrl,
        supabaseAnonKey: supabaseAnonKey,
      );

      state = state.copyWith(
        loading: false,
        triggerConfig: config,
        serviceEnabled: serviceEnabled,
        authState: auth,
        batteryOptimized: !batteryIgnored,
        notificationListenerEnabled: notificationListenerEnabled,
        isMiui: isMiui,
        musicProvider: musicProvider,
        musicAppInstalled: musicAppInstalled,
        ruleConfig: ruleConfig,
        logs: logLines,
      );

      // Load pending likes count
      final pendingLikes = await _settingsRepository.loadPendingLikes();
      if (pendingLikes.isNotEmpty) {
        state = state.copyWith(pendingLikesCount: pendingLikes.length);
      }

      _nativeEventsSub ??=
          _platformServiceRepository.events().listen(_onNativeEvent);
      _linkSub ??= _appLinks.uriLinkStream.listen(_onIncomingLink);
      _connectivitySub ??= Connectivity()
          .onConnectivityChanged
          .listen(_onConnectivityChanged);
    } catch (error) {
      state = state.copyWith(
        loading: false,
        lastError: error.toString(),
      );
    }
  }

  Future<void> toggleService(bool enabled) async {
    try {
      await ensureRuntimePermissions();
      if (enabled) {
        await _platformServiceRepository.startForegroundListener();
      } else {
        await _platformServiceRepository.stopForegroundListener();
      }
      await _settingsRepository.saveServiceEnabled(enabled);
      state = state.copyWith(serviceEnabled: enabled, clearError: true);
      await addLog(
        actionType: 'service_toggle',
        result: LogResult.success,
        message: 'Service ${enabled ? 'enabled' : 'disabled'}',
      );
    } catch (error) {
      state = state.copyWith(lastError: error.toString());
    }
  }

  Future<void> ensureRuntimePermissions() async {
    final notificationStatus = await Permission.notification.status;
    if (notificationStatus.isGranted) {
      await addLog(
        actionType: 'permission_notification',
        result: LogResult.info,
        message: 'Notification permission already granted',
      );
      return;
    }

    final requested = await Permission.notification.request();
    if (requested.isGranted) {
      await addLog(
        actionType: 'permission_notification',
        result: LogResult.success,
        message: 'Notification permission granted',
      );
    } else if (requested.isPermanentlyDenied) {
      await addLog(
        actionType: 'permission_notification',
        result: LogResult.failure,
        message: 'Notification permission permanently denied; opening app settings',
      );
      await _platformServiceRepository.openNotificationSettings();
    } else {
      await addLog(
        actionType: 'permission_notification',
        result: LogResult.failure,
        message: 'Notification permission denied',
      );
    }
  }

  /// Switches the music service that likes go to, both here and in the
  /// native listener, and refreshes the connection state shown for it.
  Future<void> selectMusicProvider(MusicProvider provider) async {
    if (provider == state.musicProvider) return;
    try {
      await _settingsRepository.saveMusicProvider(provider);
      await _platformServiceRepository.updateMusicProvider(provider);
      final auth = await _musicServiceRepository.getAuthState();
      final installed =
          await _platformServiceRepository.isMusicAppInstalled(provider);
      state = state.copyWith(
        musicProvider: provider,
        authState: auth,
        musicAppInstalled: installed,
        clearError: true,
        clearLikeResult: true,
      );
      await addLog(
        actionType: 'music_provider',
        result: LogResult.success,
        message: 'Music service set to ${provider.displayName}'
            '${auth.connected ? '' : ' (not connected)'}',
      );
    } catch (error) {
      state = state.copyWith(lastError: error.toString());
    }
  }

  Future<void> connectMusicService() async {
    final name = state.musicProvider.displayName;
    try {
      if (!state.musicAppInstalled) {
        await addLog(
          actionType: 'service_connect',
          result: LogResult.failure,
          message: '$name app is not installed.',
        );
      }
      await _musicServiceRepository.connect();
      await addLog(
        actionType: 'service_connect',
        result: LogResult.info,
        message: 'Waiting for $name sign-in...',
      );
    } catch (error) {
      state = state.copyWith(lastError: error.toString());
    }
  }

  /// Called after a sign-in completed outside [connectMusicService] (e.g.
  /// YouTube Music's device code approved on another device).
  Future<void> onMusicServiceSignedIn() async {
    try {
      final auth = await _musicServiceRepository.getAuthState();
      state = state.copyWith(authState: auth, clearError: true);
      await addLog(
        actionType: 'service_connect',
        result: LogResult.success,
        message: '${state.musicProvider.displayName} connected successfully',
      );
    } catch (error) {
      state = state.copyWith(lastError: error.toString());
    }
  }

  Future<void> disconnectMusicService() async {
    await _musicServiceRepository.disconnect();
    state = state.copyWith(
      authState: const SpotifyAuthState.disconnected(),
      clearError: true,
    );
    await addLog(
      actionType: 'service_disconnect',
      result: LogResult.success,
      message: '${state.musicProvider.displayName} disconnected',
    );
  }

  Future<void> saveTriggerConfig(TriggerConfig config) async {
    await _settingsRepository.saveTriggerConfig(config);
    await _platformServiceRepository.updateTriggerConfig(config);
    state = state.copyWith(triggerConfig: config, clearError: true);
    await addLog(
      actionType: 'trigger_config',
      result: LogResult.success,
      message: 'Trigger config updated to ${config.pattern} (${config.windowMs}ms)',
    );
  }

  Future<void> saveRuleConfig(RuleConfig config) async {
    final normalized = config.copyWith(
      archivePlaylistName: config.archivePlaylistName.trim(),
      bestOfPlaylistName: config.bestOfPlaylistName.trim(),
    );
    final errors = normalized.validate();
    if (errors.isNotEmpty) {
      state = state.copyWith(lastError: errors.join(' '));
      return;
    }
    await _settingsRepository.saveRuleConfig(normalized);
    await _platformServiceRepository.updateRuleConfig(normalized);
    state = state.copyWith(ruleConfig: normalized, clearError: true);
    await addLog(
      actionType: 'rule_config',
      result: LogResult.success,
      message: 'Rule config updated',
    );
  }

  Future<void> requestBatteryOptimizationExemption() async {
    await _platformServiceRepository.openIgnoreBatteryOptimizationSettings();
    await refreshBatteryOptimizationStatus();
  }

  Future<void> openBatteryOptimizationSettings() async {
    await _platformServiceRepository.openBatteryOptimizationSettings();
  }

  Future<void> openMiuiAutostartSettings() async {
    await _platformServiceRepository.openMiuiAutostartSettings();
  }

  Future<void> openNotificationSettings() async {
    await _platformServiceRepository.openNotificationSettings();
  }

  Future<void> openNotificationListenerSettings() async {
    await _platformServiceRepository.openNotificationListenerSettings();
    await addLog(
      actionType: 'notification_listener',
      result: LogResult.info,
      message: 'Opened notification access settings; enable access and tap refresh',
    );
  }

  Future<void> refreshNotificationListenerStatus() async {
    final enabled = await _platformServiceRepository.isNotificationListenerEnabled();
    state = state.copyWith(notificationListenerEnabled: enabled);
    if (!enabled) {
      await addLog(
        actionType: 'notification_listener',
        result: LogResult.failure,
        message: 'Notification access is disabled; playback-state fallback is unavailable',
      );
    }
  }

  Future<void> refreshBatteryOptimizationStatus() async {
    final ignored = await _platformServiceRepository.isIgnoringBatteryOptimizations();
    state = state.copyWith(batteryOptimized: !ignored);
  }

  Future<void> likeCurrentTrackNow() async {
    try {
      state = state.copyWith(clearError: true, clearLikeResult: true, liking: true);
      final result = await _musicServiceRepository.likeCurrentTrack();
      state = state.copyWith(lastLikeResult: result, liking: false);
      if (result.skippedCooldown) {
        await addLog(
          actionType: 'like_track',
          targetId: result.trackName,
          result: LogResult.info,
          message: 'Skipped — ${result.trackName} was liked recently (cooldown)',
        );
        return;
      }
      await addLog(
        actionType: 'like_track',
        targetId: result.trackName,
        result: LogResult.success,
        message: 'Liked: ${result.trackName} (x${result.trackLikeCount})',
      );
      if (result.removedFromArchive) {
        await addLog(
          actionType: 'archive_remove',
          result: LogResult.success,
          message: 'Removed from archive playlist',
        );
      }
      if (result.addedToBestOf) {
        await addLog(
          actionType: 'best_of_add',
          result: LogResult.success,
          message: 'Added to best-of playlist',
        );
      }
      if (result.followedArtistNames.isNotEmpty) {
        await addLog(
          actionType: 'follow_artist',
          result: LogResult.success,
          message: 'Auto-followed: ${result.followedArtistNames.join(", ")}',
        );
      }
    } on MusicServiceNotConnectedException catch (error) {
      state = state.copyWith(lastError: error.toString(), liking: false);
      await _logNotConnected(error);
    } catch (error) {
      state = state.copyWith(lastError: error.toString(), liking: false);
      await addLog(
        actionType: 'like_track',
        result: LogResult.failure,
        httpCode: error is MusicServiceHttpException ? error.statusCode : null,
        message: 'Like command failed: $error',
      );
      // Try to queue for offline retry — we need the track info.
      // If we can still reach Spotify to get current track, queue it.
      await _tryQueueCurrentTrack();
    }
  }

  /// Nothing was sent: the selected service has no sign-in. Not queued for
  /// retry, since coming back online won't fix it.
  Future<void> _logNotConnected(MusicServiceNotConnectedException error) {
    return addLog(
      actionType: 'like_track',
      result: LogResult.failure,
      message: 'Like skipped: $error. Connect it under Connected services.',
    );
  }

  Future<void> _tryQueueCurrentTrack() async {
    try {
      // Attempt to get current track info for queuing — may also fail if fully offline
      final auth = await _musicServiceRepository.getAuthState();
      if (!auth.connected || auth.accessToken == null) return;

      // If we can't even get track info, nothing to queue
    } catch (_) {
      // Fully offline — can't queue without track info
    }
  }

  Future<void> _onConnectivityChanged(List<ConnectivityResult> result) async {
    if (result.contains(ConnectivityResult.none)) return;

    final pending = await _settingsRepository.loadPendingLikes();
    if (pending.isEmpty) return;

    await addLog(
      actionType: 'process_pending',
      result: LogResult.info,
      message: 'Online — processing ${pending.length} queued like(s)...',
    );
    final processed = await _musicServiceRepository.processPendingLikes(pending);
    if (processed > 0) {
      await addLog(
        actionType: 'process_pending',
        result: LogResult.success,
        message: 'Processed $processed queued like(s)',
      );
      final remaining = await _settingsRepository.loadPendingLikes();
      state = state.copyWith(pendingLikesCount: remaining.length);
    }
  }

  /// Queue a track for offline retry.
  Future<void> queueTrackForLater(TrackInfo trackInfo) async {
    final pending = PendingLike(
      trackId: trackInfo.trackId,
      trackName: trackInfo.trackName,
      artistIds: trackInfo.artistIds,
      artistNames: trackInfo.artistNames,
      queuedAt: DateTime.now().toUtc(),
    );
    await _settingsRepository.addPendingLike(pending);
    final count = (await _settingsRepository.loadPendingLikes()).length;
    state = state.copyWith(pendingLikesCount: count);
    await addLog(
      actionType: 'queue_pending',
      targetId: trackInfo.trackId,
      result: LogResult.info,
      message: 'Queued for later: ${trackInfo.trackName}',
    );
  }

  Future<void> clearLogs() async {
    await _settingsRepository.clearLogs();
    state = state.copyWith(logs: <AppLog>[]);
  }

  Future<void> exportDiagnostics() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      final likeCounts = await _musicServiceRepository.loadAllLikeCounts();

      final bundle = <String, dynamic>{
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'app': <String, dynamic>{
          'packageName': packageInfo.packageName,
          'version': packageInfo.version,
          'buildNumber': packageInfo.buildNumber,
        },
        'device': <String, dynamic>{
          'manufacturer': androidInfo.manufacturer,
          'model': androidInfo.model,
          'androidRelease': androidInfo.version.release,
          'sdkInt': androidInfo.version.sdkInt,
        },
        'service': <String, dynamic>{
          'enabled': state.serviceEnabled,
          'isMiui': state.isMiui,
          'batteryOptimized': state.batteryOptimized,
          'notificationListenerEnabled': state.notificationListenerEnabled,
          'musicProvider': state.musicProvider.id,
          'musicAppInstalled': state.musicAppInstalled,
        },
        // Only non-secret auth fields — never export accessToken/refreshToken.
        'auth': <String, dynamic>{
          'connected': state.authState.connected,
          'isExpired': state.authState.isExpired,
        },
        'triggerConfig': <String, dynamic>{
          'pattern': state.triggerConfig.pattern,
          'windowMs': state.triggerConfig.windowMs,
          'debounceMs': state.triggerConfig.debounceMs,
        },
        'ruleConfig': state.ruleConfig.toJson(),
        'likeCounts': likeCounts,
        'logs': state.logs.map((log) => log.toJson()).toList(),
      };

      final jsonText = const JsonEncoder.withIndent('  ').convert(bundle);
      await SharePlus.instance.share(
        ShareParams(text: jsonText, subject: 'Like Spotify diagnostics export'),
      );
      await addLog(
        actionType: 'export_diagnostics',
        result: LogResult.success,
        message: 'Exported diagnostics bundle (${state.logs.length} log entries)',
      );
    } catch (error) {
      state = state.copyWith(lastError: error.toString());
      await addLog(
        actionType: 'export_diagnostics',
        result: LogResult.failure,
        message: 'Diagnostics export failed: $error',
      );
    }
  }

  Future<void> addLog({
    required String actionType,
    String? targetId,
    LogResult result = LogResult.info,
    int? httpCode,
    required String message,
  }) async {
    await _settingsRepository.appendLog(AppLog(
      at: DateTime.now().toUtc(),
      actionType: actionType,
      targetId: targetId,
      result: result,
      httpCode: httpCode,
      message: message,
    ));
    final logs = await _settingsRepository.loadLogs();
    state = state.copyWith(logs: logs);
  }

  Future<void> _onIncomingLink(Uri uri) async {
    try {
      final handled = await _musicServiceRepository.handleAuthCallback(uri);
      if (handled) {
        final auth = await _musicServiceRepository.getAuthState();
        state = state.copyWith(authState: auth, clearError: true);
        await addLog(
          actionType: 'oauth_callback',
          result: LogResult.success,
          message: '${state.musicProvider.displayName} connected successfully',
        );
      }
    } catch (error) {
      state = state.copyWith(lastError: 'OAuth callback failed: $error');
    }
  }

  void _onNativeEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    final value = event['value'];

    if (type == 'state' && value is bool) {
      state = state.copyWith(serviceEnabled: value);
      return;
    }

    if (type == 'log' && value is String) {
      unawaited(addLog(
        actionType: event['actionType'] as String? ?? 'native',
        targetId: event['targetId'] as String?,
        result: LogResult.fromName(event['result'] as String?),
        httpCode: event['httpCode'] as int?,
        message: value,
      ));
      return;
    }

    if (type == 'media' && value is String) {
      unawaited(addLog(
        actionType: 'media_event',
        result: LogResult.info,
        message: 'Media event: $value',
      ));
      return;
    }

    if (type == 'trigger_like') {
      unawaited(_handleNativeTriggerLike());
      return;
    }
  }

  Future<void> _handleNativeTriggerLike() async {
    try {
      state = state.copyWith(clearError: true, clearLikeResult: true, liking: true);
      final result = await _musicServiceRepository.likeCurrentTrack();
      state = state.copyWith(lastLikeResult: result, liking: false);

      await _platformServiceRepository.playFeedbackTone(
        success: result.trackLiked || result.skippedCooldown,
      );

      if (result.skippedCooldown) {
        await addLog(
          actionType: 'like_track',
          targetId: result.trackName,
          result: LogResult.info,
          message: 'Skipped — ${result.trackName} was liked recently (cooldown)',
        );
        return;
      }

      await addLog(
        actionType: 'like_track',
        targetId: result.trackName,
        result: LogResult.success,
        message: 'Liked: ${result.trackName} (x${result.trackLikeCount})',
      );
      if (result.removedFromArchive) {
        await addLog(
          actionType: 'archive_remove',
          result: LogResult.success,
          message: 'Removed from archive playlist',
        );
      }
      if (result.addedToBestOf) {
        await addLog(
          actionType: 'best_of_add',
          result: LogResult.success,
          message: 'Added to best-of playlist',
        );
      }
      if (result.followedArtistNames.isNotEmpty) {
        await addLog(
          actionType: 'follow_artist',
          result: LogResult.success,
          message: 'Auto-followed: ${result.followedArtistNames.join(", ")}',
        );
      }
    } on MusicServiceNotConnectedException catch (error) {
      state = state.copyWith(lastError: error.toString(), liking: false);
      await _platformServiceRepository.playFeedbackTone(success: false);
      await _logNotConnected(error);
    } catch (error) {
      state = state.copyWith(lastError: error.toString(), liking: false);
      await _platformServiceRepository.playFeedbackTone(success: false);
      await addLog(
        actionType: 'like_track',
        result: LogResult.failure,
        httpCode: error is MusicServiceHttpException ? error.statusCode : null,
        message: 'Like from trigger failed: $error',
      );
      await _tryQueueCurrentTrack();
    }
  }

  @override
  void dispose() {
    _nativeEventsSub?.cancel();
    _linkSub?.cancel();
    _connectivitySub?.cancel();
    super.dispose();
  }
}
