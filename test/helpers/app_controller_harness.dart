import 'package:app_links/app_links.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/core/app_constants.dart';
import 'package:like_spotify_mobile_app/data/music/active_music_service_repository.dart';
import 'package:like_spotify_mobile_app/domain/entities/app_log.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_routing.dart';
import 'package:like_spotify_mobile_app/domain/entities/pending_like.dart';
import 'package:like_spotify_mobile_app/domain/entities/rule_config.dart';
import 'package:like_spotify_mobile_app/domain/entities/spotify_auth_state.dart';
import 'package:like_spotify_mobile_app/domain/entities/trigger_config.dart';
import 'package:like_spotify_mobile_app/domain/repositories/device_sign_in_repository.dart';
import 'package:like_spotify_mobile_app/presentation/state/app_controller.dart';
import 'package:like_spotify_mobile_app/presentation/state/app_providers.dart';
import 'package:mocktail/mocktail.dart';

import 'mocks.dart';

class MockAppLinks extends Mock implements AppLinks {}

class MockDeviceSignInRepository extends Mock
    implements DeviceSignInRepository {}

/// Fallbacks for the `any()` matchers [AppControllerHarness] stubs with.
/// Call from `setUpAll`, before the first harness is built.
void registerAppControllerFallbacks() {
  registerFallbackValue(MusicProvider.defaultProvider);
  registerFallbackValue(MusicRoutingMode.defaultMode);
  registerFallbackValue(
    const TriggerConfig(pattern: '', windowMs: 0, debounceMs: 0),
  );
  registerFallbackValue(RuleConfig.defaults());
  registerFallbackValue(AppLog(at: DateTime.utc(2025), message: ''));
}

/// [AppController] subscribes to connectivity_plus while starting up. Without
/// a handler the plugin channel reports a `MissingPluginException` that fails
/// the test; a stream that never emits is all these tests need.
void silenceConnectivityChannel() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
    const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
    MockStreamHandler.inline(onListen: (Object? arguments, sink) {}),
  );
}

/// Every dependency [AppController] touches at start-up, stubbed, so a test
/// only has to say what it is actually about.
///
/// [music] is the real [ActiveMusicServiceRepository] over two mock services,
/// because the behaviour under test is which of them a switch reaches — and
/// which of them it leaves alone.
class AppControllerHarness {
  AppControllerHarness({MusicProvider selected = MusicProvider.spotify})
      : _selected = selected {
    music = ActiveMusicServiceRepository(
      settingsRepository: settings,
      platformServiceRepository: platform,
      repositories: <MusicProvider, MockMusicServiceRepository>{
        MusicProvider.spotify: spotify,
        MusicProvider.ytmusic: ytmusic,
      },
    );
    _stubStartUp();
  }

  final MockSettingsRepository settings = MockSettingsRepository();
  final MockPlatformServiceRepository platform = MockPlatformServiceRepository();
  final MockMusicServiceRepository spotify = MockMusicServiceRepository();
  final MockMusicServiceRepository ytmusic = MockMusicServiceRepository();
  final MockDeviceSignInRepository signIn = MockDeviceSignInRepository();
  final MockAppLinks appLinks = MockAppLinks();
  late final ActiveMusicServiceRepository music;

  MusicProvider _selected;
  MusicRoutingMode _routingMode = MusicRoutingMode.defaultMode;

  /// What `readMusicSessions` answers; a test that cares sets it before acting.
  MusicSessionSnapshot sessions = const MusicSessionSnapshot();

  /// What `loadMusicProvider` answers right now: an in-memory stand-in for
  /// SharedPreferences, so a saved choice is visible to the next read — which
  /// is how [ActiveMusicServiceRepository] picks the service to talk to.
  MusicProvider get selected => _selected;

  /// The stored routing mode, same in-memory stand-in as [selected].
  MusicRoutingMode get routingMode => _routingMode;

  void _stubStartUp() {
    when(() => settings.loadMusicProvider()).thenAnswer((_) async => _selected);
    when(() => settings.saveMusicProvider(any())).thenAnswer((invocation) async {
      _selected = invocation.positionalArguments.single as MusicProvider;
    });
    when(() => settings.loadMusicRoutingMode())
        .thenAnswer((_) async => _routingMode);
    when(() => settings.saveMusicRoutingMode(any()))
        .thenAnswer((invocation) async {
      _routingMode = invocation.positionalArguments.single as MusicRoutingMode;
    });
    when(() => settings.loadTriggerConfig()).thenAnswer(
      (_) async => const TriggerConfig(
        pattern: AppConstants.defaultPattern,
        windowMs: AppConstants.defaultWindowMs,
        debounceMs: AppConstants.defaultDebounceMs,
      ),
    );
    when(() => settings.loadRuleConfig())
        .thenAnswer((_) async => RuleConfig.defaults());
    when(() => settings.loadLogs()).thenAnswer((_) async => <AppLog>[]);
    when(() => settings.loadPendingLikes())
        .thenAnswer((_) async => <PendingLike>[]);
    when(() => settings.appendLog(any())).thenAnswer((_) async {});

    when(() => platform.isServiceEnabled()).thenAnswer((_) async => false);
    when(() => platform.isIgnoringBatteryOptimizations())
        .thenAnswer((_) async => true);
    when(() => platform.isNotificationListenerEnabled())
        .thenAnswer((_) async => false);
    when(() => platform.isMiuiDevice()).thenAnswer((_) async => false);
    when(() => platform.isMusicAppInstalled(any()))
        .thenAnswer((_) async => true);
    when(() => platform.updateMusicProvider(any())).thenAnswer((_) async {});
    when(() => platform.updateMusicRoutingMode(any())).thenAnswer((_) async {});
    when(() => platform.readMusicSessions()).thenAnswer((_) async => sessions);
    when(() => platform.updateTriggerConfig(any())).thenAnswer((_) async {});
    when(() => platform.updateRuleConfig(any())).thenAnswer((_) async {});
    when(
      () => platform.syncSupabaseConfig(
        supabaseUrl: any(named: 'supabaseUrl'),
        supabaseAnonKey: any(named: 'supabaseAnonKey'),
      ),
    ).thenAnswer((_) async {});
    when(() => platform.events())
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());

    for (final repository in <MockMusicServiceRepository>[spotify, ytmusic]) {
      when(() => repository.getAuthState())
          .thenAnswer((_) async => const SpotifyAuthState.disconnected());
    }

    when(() => appLinks.uriLinkStream)
        .thenAnswer((_) => const Stream<Uri>.empty());
    when(() => signIn.loadClientCredentials()).thenAnswer((_) async => null);
    when(() => signIn.cancelSignIn()).thenReturn(null);
  }

  AppController build() => AppController(
        settingsRepository: settings,
        platformServiceRepository: platform,
        musicServiceRepository: music,
        musicRoutingRepository: music,
        appLinks: appLinks,
      );

  /// Overrides that point `appControllerProvider` and the YouTube Music
  /// sign-in controller at these mocks.
  List<Override> get overrides => <Override>[
        settingsRepositoryProvider.overrideWithValue(settings),
        platformServiceRepositoryProvider.overrideWithValue(platform),
        musicServiceRepositoryProvider.overrideWithValue(music),
        musicRoutingRepositoryProvider.overrideWithValue(music),
        deviceSignInRepositoryProvider.overrideWithValue(signIn),
        appLinksProvider.overrideWithValue(appLinks),
      ];
}
