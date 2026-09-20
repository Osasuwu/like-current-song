import '../../domain/entities/app_log.dart';
import '../../domain/entities/like_result.dart';
import '../../domain/entities/music_provider.dart';
import '../../domain/entities/music_routing.dart';
import '../../domain/entities/rule_config.dart';
import '../../domain/entities/spotify_auth_state.dart';
import '../../domain/entities/trigger_config.dart';

class AppState {
  final bool serviceEnabled;
  final bool loading;
  final bool isMiui;
  final bool batteryOptimized;
  final bool notificationListenerEnabled;
  final MusicProvider musicProvider;

  /// Whether likes follow [musicProvider] or whichever service is playing.
  final MusicRoutingMode musicRoutingMode;

  /// The services that are signed in. Automatic routing needs at least two,
  /// since with one there is nothing to choose between.
  final Set<MusicProvider> connectedProviders;

  /// Whether [musicProvider]'s Android app is installed.
  final bool musicAppInstalled;

  /// Sign-in state of [musicProvider].
  final SpotifyAuthState authState;
  final TriggerConfig triggerConfig;
  final RuleConfig ruleConfig;
  final List<AppLog> logs;
  final String? lastError;
  final LikeResult? lastLikeResult;
  final bool liking;
  final int pendingLikesCount;

  /// Whether a headset press can actually reach the trigger. Notification
  /// access is not an extra: the media button belongs to the player, so
  /// watching its playback state is the only way in. Without the grant the
  /// service runs and hears nothing.
  bool get triggerCanFire => serviceEnabled && notificationListenerEnabled;

  /// Whether automatic routing can be offered: it needs notification access
  /// to see media sessions, and two connected services to choose between.
  bool get canRouteAutomatically =>
      notificationListenerEnabled && connectedProviders.length >= 2;

  /// Why automatic routing is not on offer, or null when it is. One line, for
  /// the Connected services screen.
  String? get automaticRoutingBlockedReason {
    if (!notificationListenerEnabled) {
      return 'Automatic needs notification access to see what is playing.';
    }
    if (connectedProviders.length < 2) {
      return 'Automatic needs two connected services to choose between.';
    }
    return null;
  }

  const AppState({
    required this.serviceEnabled,
    required this.loading,
    required this.isMiui,
    required this.batteryOptimized,
    required this.notificationListenerEnabled,
    this.musicProvider = MusicProvider.defaultProvider,
    this.musicRoutingMode = MusicRoutingMode.defaultMode,
    this.connectedProviders = const <MusicProvider>{},
    required this.musicAppInstalled,
    required this.authState,
    required this.triggerConfig,
    required this.ruleConfig,
    required this.logs,
    required this.lastError,
    this.lastLikeResult,
    this.liking = false,
    this.pendingLikesCount = 0,
  });

  factory AppState.initial(TriggerConfig config) {
    return AppState(
      serviceEnabled: false,
      loading: false,
      isMiui: false,
      batteryOptimized: true,
      notificationListenerEnabled: false,
      musicAppInstalled: false,
      authState: const SpotifyAuthState.disconnected(),
      triggerConfig: config,
      ruleConfig: RuleConfig.defaults(),
      logs: const <AppLog>[],
      lastError: null,
    );
  }

  AppState copyWith({
    bool? serviceEnabled,
    bool? loading,
    bool? isMiui,
    bool? batteryOptimized,
    bool? notificationListenerEnabled,
    MusicProvider? musicProvider,
    MusicRoutingMode? musicRoutingMode,
    Set<MusicProvider>? connectedProviders,
    bool? musicAppInstalled,
    SpotifyAuthState? authState,
    TriggerConfig? triggerConfig,
    RuleConfig? ruleConfig,
    List<AppLog>? logs,
    String? lastError,
    bool clearError = false,
    LikeResult? lastLikeResult,
    bool clearLikeResult = false,
    bool? liking,
    int? pendingLikesCount,
  }) {
    return AppState(
      serviceEnabled: serviceEnabled ?? this.serviceEnabled,
      loading: loading ?? this.loading,
      isMiui: isMiui ?? this.isMiui,
      batteryOptimized: batteryOptimized ?? this.batteryOptimized,
      notificationListenerEnabled:
          notificationListenerEnabled ?? this.notificationListenerEnabled,
      musicProvider: musicProvider ?? this.musicProvider,
      musicRoutingMode: musicRoutingMode ?? this.musicRoutingMode,
      connectedProviders: connectedProviders ?? this.connectedProviders,
      musicAppInstalled: musicAppInstalled ?? this.musicAppInstalled,
      authState: authState ?? this.authState,
      triggerConfig: triggerConfig ?? this.triggerConfig,
      ruleConfig: ruleConfig ?? this.ruleConfig,
      logs: logs ?? this.logs,
      lastError: clearError ? null : (lastError ?? this.lastError),
      lastLikeResult: clearLikeResult ? null : (lastLikeResult ?? this.lastLikeResult),
      liking: liking ?? this.liking,
      pendingLikesCount: pendingLikesCount ?? this.pendingLikesCount,
    );
  }
}
