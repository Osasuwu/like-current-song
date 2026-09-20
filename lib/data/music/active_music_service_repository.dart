import '../../domain/entities/like_result.dart';
import '../../domain/entities/music_provider.dart';
import '../../domain/entities/music_routing.dart';
import '../../domain/entities/pending_like.dart';
import '../../domain/entities/spotify_auth_state.dart';
import '../../domain/entities/track_info.dart';
import '../../domain/repositories/music_routing_repository.dart';
import '../../domain/repositories/music_service_repository.dart';
import '../../domain/repositories/platform_service_repository.dart';
import '../../domain/repositories/settings_repository.dart';

/// Routes every [MusicServiceRepository] call to one of the registered music
/// services, and owns the Dart half of the routing rule.
///
/// Settings are read on each call, so a change made in Settings applies to the
/// next like without rebuilding anything. Every [MusicProvider] must have a
/// registered repository.
///
/// Which service a **like** goes to depends on [MusicRoutingMode], in this
/// order:
///
/// 1. [MusicRoutingMode.picker] (the default, and what every upgraded install
///    keeps) — the service chosen in Connected services, always.
/// 2. [MusicRoutingMode.automatic] — the single connected service that owns a
///    playing media session.
/// 3. Automatic with nothing playing, or with two services playing at once —
///    the connected service that played most recently.
/// 4. Automatic with no usable session information at all, including when
///    notification access is off or the platform call fails — the picked
///    service again, as a fallback.
///
/// Never a service the user is not signed in to: an unconnected provider is
/// excluded from steps 2 and 3, and only the explicit pick can select one (and
/// then it fails loudly as a disconnected service should, rather than silently
/// liking on the other service).
///
/// Everything that is *not* a like — sign-in state, connect, disconnect, the
/// OAuth callback, like counters — stays on the picked service regardless of
/// mode, because those all serve the Connected services screen, where the
/// picked service is the subject.
///
/// The same rule lives in `MusicProvider.resolve` on the Kotlin side, which is
/// what routes the like when the trigger fires with the Flutter engine
/// detached. Change one, change the other.
class ActiveMusicServiceRepository
    implements MusicServiceRepository, MusicRoutingRepository {
  ActiveMusicServiceRepository({
    required SettingsRepository settingsRepository,
    required PlatformServiceRepository platformServiceRepository,
    required Map<MusicProvider, MusicServiceRepository> repositories,
  })  : _settingsRepository = settingsRepository,
        _platformServiceRepository = platformServiceRepository,
        _repositories = Map<MusicProvider, MusicServiceRepository>.unmodifiable(
          repositories,
        ) {
    final missing =
        MusicProvider.values.where((p) => !_repositories.containsKey(p));
    if (missing.isNotEmpty) {
      throw ArgumentError.value(
        repositories.keys.map((p) => p.id).toList(),
        'repositories',
        'No repository registered for: ${missing.map((p) => p.id).join(', ')}',
      );
    }
  }

  final SettingsRepository _settingsRepository;
  final PlatformServiceRepository _platformServiceRepository;
  final Map<MusicProvider, MusicServiceRepository> _repositories;

  @override
  void Function(MusicRoutingDecision decision)? onAutomaticRouting;

  /// The repository a like placed right now would go to. See the class doc for
  /// the order; [resolveRouting] is the same decision with its reason.
  Future<MusicServiceRepository> resolve() async {
    final decision = await resolveRouting();
    if (decision.automatic) onAutomaticRouting?.call(decision);
    return _repositories[decision.provider]!;
  }

  @override
  Future<MusicRoutingDecision> resolveRouting() async {
    final picked = await _settingsRepository.loadMusicProvider();
    final mode = await _settingsRepository.loadMusicRoutingMode();
    if (mode != MusicRoutingMode.automatic) {
      return MusicRoutingDecision(
        provider: picked,
        reason: MusicRoutingReason.picker,
      );
    }

    final connected = await connectedProviders();
    final snapshot = await _readSessions();

    final playing =
        snapshot.playing.where(connected.contains).toList(growable: false);
    if (playing.length == 1) {
      return MusicRoutingDecision(
        provider: playing.single,
        reason: MusicRoutingReason.playingSession,
      );
    }

    // Nothing playing, or both services playing at once — neither tells us
    // which one the user is listening to, so take the one they were last
    // listening to.
    final last = snapshot.lastPlaying;
    if (last != null && connected.contains(last)) {
      return MusicRoutingDecision(
        provider: last,
        reason: MusicRoutingReason.lastPlaying,
      );
    }

    return MusicRoutingDecision(
      provider: picked,
      reason: MusicRoutingReason.pickerFallback,
    );
  }

  /// An unreadable snapshot is an answer, not an error: without notification
  /// access there are no sessions to see, and routing falls back to the picker.
  Future<MusicSessionSnapshot> _readSessions() async {
    try {
      return await _platformServiceRepository.readMusicSessions();
    } catch (_) {
      return const MusicSessionSnapshot();
    }
  }

  @override
  Future<Set<MusicProvider>> connectedProviders() async {
    final connected = <MusicProvider>{};
    for (final entry in _repositories.entries) {
      try {
        if ((await entry.value.getAuthState()).connected) {
          connected.add(entry.key);
        }
      } catch (_) {
        // A service that cannot report its sign-in state is not a service we
        // can route a like to.
      }
    }
    return connected;
  }

  /// The repository of the service picked in Connected services, whatever the
  /// routing mode.
  Future<MusicServiceRepository> _picked() async =>
      _repositories[await _settingsRepository.loadMusicProvider()]!;

  @override
  Future<SpotifyAuthState> getAuthState() async => (await _picked()).getAuthState();

  @override
  Future<SpotifyAuthState> connect() async => (await _picked()).connect();

  @override
  Future<void> disconnect() async => (await _picked()).disconnect();

  /// Offered to every registered service, not just the selected one: an
  /// OAuth redirect must still complete if the user switched services while
  /// the browser was open. Each service ignores URIs that aren't its own.
  @override
  Future<bool> handleAuthCallback(Uri uri) async {
    for (final repository in _repositories.values) {
      if (await repository.handleAuthCallback(uri)) return true;
    }
    return false;
  }

  @override
  Future<LikeResult> likeCurrentTrack() async =>
      (await resolve()).likeCurrentTrack();

  @override
  Future<LikeResult> likeTrack(TrackInfo trackInfo) async =>
      (await resolve()).likeTrack(trackInfo);

  @override
  Future<void> refreshIfNeeded() async => (await _picked()).refreshIfNeeded();

  /// Hands each service only the likes queued for it: a Spotify like must
  /// never be replayed on YouTube Music, or the other way round. In picker
  /// mode only the picked service's queue is drained, so likes for the other
  /// service wait until it is picked again; in automatic mode every connected
  /// service drains its own, since automatic routing can have filled more than
  /// one queue.
  @override
  Future<int> processPendingLikes(List<PendingLike> pending) async {
    final mode = await _settingsRepository.loadMusicRoutingMode();
    final targets = mode == MusicRoutingMode.automatic
        ? await connectedProviders()
        : <MusicProvider>{await _settingsRepository.loadMusicProvider()};

    var processed = 0;
    for (final provider in targets) {
      final own = pending.where((like) => like.isFor(provider)).toList();
      if (own.isEmpty) continue;
      processed += await _repositories[provider]!.processPendingLikes(own);
    }
    return processed;
  }

  @override
  Future<Map<String, Map<String, int>>> loadAllLikeCounts() async =>
      (await _picked()).loadAllLikeCounts();
}
