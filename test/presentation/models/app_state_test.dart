import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/app_log.dart';
import 'package:like_spotify_mobile_app/domain/entities/rule_config.dart';
import 'package:like_spotify_mobile_app/domain/entities/spotify_auth_state.dart';
import 'package:like_spotify_mobile_app/domain/entities/trigger_config.dart';
import 'package:like_spotify_mobile_app/presentation/state/app_state.dart';

void main() {
  group('AppState', () {
    final testConfig = TriggerConfig(
      pattern: 'pause,play',
      windowMs: 5000,
      debounceMs: 500,
    );

    AppState buildState({
      bool serviceEnabled = false,
      bool loading = false,
      bool isMiui = false,
      bool batteryOptimized = true,
      bool notificationListenerEnabled = false,
      bool musicAppInstalled = false,
      SpotifyAuthState authState = const SpotifyAuthState.disconnected(),
      TriggerConfig? triggerConfig,
      RuleConfig? ruleConfig,
      List<AppLog> logs = const <AppLog>[],
      String? lastError,
    }) {
      return AppState(
        serviceEnabled: serviceEnabled,
        loading: loading,
        isMiui: isMiui,
        batteryOptimized: batteryOptimized,
        notificationListenerEnabled: notificationListenerEnabled,
        musicAppInstalled: musicAppInstalled,
        authState: authState,
        triggerConfig: triggerConfig ?? testConfig,
        ruleConfig: ruleConfig ?? RuleConfig.defaults(),
        logs: logs,
        lastError: lastError,
      );
    }

    group('initial factory', () {
      test('creates initial state with correct defaults', () {
        final state = AppState.initial(testConfig);

        expect(state.serviceEnabled, equals(false));
        expect(state.loading, equals(false));
        expect(state.isMiui, equals(false));
        expect(state.batteryOptimized, equals(true));
        expect(state.notificationListenerEnabled, equals(false));
        expect(state.musicAppInstalled, equals(false));
      });

      test('initializes with disconnected auth state', () {
        final state = AppState.initial(testConfig);

        expect(state.authState.connected, equals(false));
        expect(state.authState.accessToken, isNull);
        expect(state.authState.refreshToken, isNull);
      });

      test('sets default rule config with extra actions off', () {
        final state = AppState.initial(testConfig);

        expect(state.ruleConfig.archiveRemoveEnabled, isFalse);
        expect(state.ruleConfig.archivePlaylistName, isEmpty);
        expect(state.ruleConfig.bestEnabled, isFalse);
        expect(state.ruleConfig.bestPlaylistName, isEmpty);
        expect(state.ruleConfig.followArtistEnabled, isFalse);
      });

      test('initializes with empty logs', () {
        final state = AppState.initial(testConfig);

        expect(state.logs, equals([]));
        expect(state.logs.length, equals(0));
      });

      test('initializes with no error', () {
        final state = AppState.initial(testConfig);

        expect(state.lastError, isNull);
      });

      test('stores provided trigger config', () {
        final state = AppState.initial(testConfig);

        expect(state.triggerConfig, equals(testConfig));
        expect(state.triggerConfig.pattern, equals('pause,play'));
      });
    });

    group('copyWith basic updates', () {
      test('updates serviceEnabled field', () {
        final state = AppState.initial(testConfig);
        final updated = state.copyWith(serviceEnabled: true);

        expect(updated.serviceEnabled, equals(true));
      });

      test('updates loading field', () {
        final state = AppState.initial(testConfig);
        final updated = state.copyWith(loading: true);

        expect(updated.loading, equals(true));
      });

      test('updates isMiui field', () {
        final state = AppState.initial(testConfig);
        final updated = state.copyWith(isMiui: true);

        expect(updated.isMiui, equals(true));
      });

      test('updates batteryOptimized field', () {
        final state = AppState.initial(testConfig);
        final updated = state.copyWith(batteryOptimized: false);

        expect(updated.batteryOptimized, equals(false));
      });

      test('updates notificationListenerEnabled field', () {
        final state = AppState.initial(testConfig);
        final updated = state.copyWith(notificationListenerEnabled: true);

        expect(updated.notificationListenerEnabled, equals(true));
      });

      test('updates musicAppInstalled field', () {
        final state = AppState.initial(testConfig);
        final updated = state.copyWith(musicAppInstalled: true);

        expect(updated.musicAppInstalled, equals(true));
      });

      test('updates ruleConfig field', () {
        final state = AppState.initial(testConfig);
        final newRuleConfig =
            RuleConfig.defaults().copyWith(archivePlaylistName: 'New Archive');
        final updated = state.copyWith(ruleConfig: newRuleConfig);

        expect(updated.ruleConfig.archivePlaylistName, equals('New Archive'));
      });
    });

    group('copyWith preserves other fields', () {
      test('updating one field preserves all others', () {
        final state = AppState.initial(testConfig);
        final updated = state.copyWith(serviceEnabled: true);

        expect(updated.serviceEnabled, equals(true));
        expect(updated.loading, equals(state.loading));
        expect(updated.isMiui, equals(state.isMiui));
        expect(updated.batteryOptimized, equals(state.batteryOptimized));
        expect(updated.notificationListenerEnabled,
            equals(state.notificationListenerEnabled));
        expect(updated.musicAppInstalled, equals(state.musicAppInstalled));
      });

      test('updating multiple fields preserves rest', () {
        final state = AppState.initial(testConfig);
        final updated = state.copyWith(
          serviceEnabled: true,
          loading: true,
          isMiui: true,
        );

        expect(updated.serviceEnabled, equals(true));
        expect(updated.loading, equals(true));
        expect(updated.isMiui, equals(true));
        expect(updated.batteryOptimized, equals(state.batteryOptimized));
        expect(updated.notificationListenerEnabled,
            equals(state.notificationListenerEnabled));
      });

      test('preserves triggerConfig when not specified', () {
        final state = AppState.initial(testConfig);
        final updated = state.copyWith(serviceEnabled: true);

        expect(updated.triggerConfig, equals(testConfig));
      });

      test('can update triggerConfig separately', () {
        final state = AppState.initial(testConfig);
        final newConfig = TriggerConfig(
          pattern: 'play',
          windowMs: 3000,
          debounceMs: 200,
        );
        final updated = state.copyWith(triggerConfig: newConfig);

        expect(updated.triggerConfig, equals(newConfig));
        expect(updated.triggerConfig.pattern, equals('play'));
      });
    });

    group('copyWith with clearError', () {
      test('sets lastError to null when clearError is true', () {
        final state = buildState(lastError: 'Some error message');

        final updated = state.copyWith(clearError: true);

        expect(updated.lastError, isNull);
      });

      test('preserves other fields when clearing error', () {
        final state = buildState(serviceEnabled: true, lastError: 'Error');

        final updated = state.copyWith(clearError: true);

        expect(updated.lastError, isNull);
        expect(updated.serviceEnabled, equals(true));
      });

      test('preserves error when clearError is false (default)', () {
        final state = buildState(lastError: 'Original error');

        final updated = state.copyWith(serviceEnabled: true);

        expect(updated.lastError, equals('Original error'));
      });

      test('clearError can override lastError parameter', () {
        final state = buildState(lastError: 'Original error');

        final updated =
            state.copyWith(lastError: 'New error', clearError: true);

        expect(updated.lastError, isNull);
      });

      test('lastError parameter without clearError sets new error', () {
        final state = buildState(lastError: null);

        final updated = state.copyWith(lastError: 'New error');

        expect(updated.lastError, equals('New error'));
      });
    });

    group('constructor with custom values', () {
      test('creates state with all custom values', () {
        final authState = SpotifyAuthState(
          accessToken: 'token',
          refreshToken: 'refresh',
          expiresAt: DateTime.now().add(Duration(hours: 1)),
          connected: true,
        );
        final logs = [
          AppLog(at: DateTime.now(), message: 'Log message'),
        ];
        final ruleConfig = RuleConfig.defaults().copyWith(
          archivePlaylistName: 'Custom Archive',
          bestPlaylistName: 'Custom Best Of',
        );

        final state = buildState(
          serviceEnabled: true,
          loading: true,
          isMiui: true,
          batteryOptimized: false,
          notificationListenerEnabled: true,
          musicAppInstalled: true,
          authState: authState,
          ruleConfig: ruleConfig,
          logs: logs,
          lastError: 'Custom error',
        );

        expect(state.serviceEnabled, equals(true));
        expect(state.loading, equals(true));
        expect(state.isMiui, equals(true));
        expect(state.batteryOptimized, equals(false));
        expect(state.notificationListenerEnabled, equals(true));
        expect(state.musicAppInstalled, equals(true));
        expect(state.authState.connected, equals(true));
        expect(state.ruleConfig.archivePlaylistName, equals('Custom Archive'));
        expect(state.ruleConfig.bestPlaylistName, equals('Custom Best Of'));
        expect(state.logs.length, equals(1));
        expect(state.lastError, equals('Custom error'));
      });
    });

    group('copyWith with multiple fields and auth state', () {
      test('updates auth state and other fields together', () {
        final state = AppState.initial(testConfig);
        final newAuthState = SpotifyAuthState(
          accessToken: 'new_token',
          refreshToken: 'new_refresh',
          expiresAt: DateTime.now().add(Duration(hours: 1)),
          connected: true,
        );

        final updated = state.copyWith(
          authState: newAuthState,
          musicAppInstalled: true,
        );

        expect(updated.authState.connected, equals(true));
        expect(updated.authState.accessToken, equals('new_token'));
        expect(updated.musicAppInstalled, equals(true));
      });
    });

    group('copyWith with logs', () {
      test('updates logs field', () {
        final state = AppState.initial(testConfig);
        final newLogs = [
          AppLog(at: DateTime.now(), message: 'First log'),
          AppLog(at: DateTime.now(), message: 'Second log'),
        ];

        final updated = state.copyWith(logs: newLogs);

        expect(updated.logs.length, equals(2));
        expect(updated.logs[0].message, equals('First log'));
        expect(updated.logs[1].message, equals('Second log'));
      });
    });
  });
}
