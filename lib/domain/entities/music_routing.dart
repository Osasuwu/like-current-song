import 'music_provider.dart';

/// How the app decides which music service a like goes to.
///
/// Mirrored by `MusicRoutingMode` in `MusicProvider.kt`, and stored
/// under the same key on both sides so a choice made in the UI applies to the
/// trigger that fires while Flutter is detached.
enum MusicRoutingMode {
  /// Always the service chosen in Connected services. The default, and what
  /// every install that predates [automatic] keeps: automatic is opt-in.
  picker(id: 'picker'),

  /// Whichever connected service currently owns a playing media session,
  /// falling back to [picker] when that cannot be answered.
  automatic(id: 'automatic');

  const MusicRoutingMode({required this.id});

  /// Stable identifier used for persistence and the platform channel.
  final String id;

  /// Used for new installs and for every install that never opted in.
  static const MusicRoutingMode defaultMode = MusicRoutingMode.picker;

  /// Resolves a persisted [id]; unknown or missing values mean [defaultMode],
  /// so an upgrade never switches an existing install to automatic.
  static MusicRoutingMode fromId(String? id) {
    for (final mode in MusicRoutingMode.values) {
      if (mode.id == id) return mode;
    }
    return defaultMode;
  }
}

/// Why a like went to the service it went to. Written to the log so a
/// mis-route is diagnosable from the Logs screen.
enum MusicRoutingReason {
  /// Automatic is off: the service is the one picked in Connected services.
  picker('picker'),

  /// Exactly one connected service owns a playing media session right now.
  playingSession('playing session'),

  /// Nothing is playing (or two services are): the service that played last.
  lastPlaying('last playing'),

  /// Automatic could answer nothing, so the picker value stands in.
  pickerFallback('picker fallback');

  const MusicRoutingReason(this.label);

  /// Human-readable form for log lines; matches the Kotlin labels.
  final String label;
}

/// The service the next like goes to, and why.
class MusicRoutingDecision {
  const MusicRoutingDecision({required this.provider, required this.reason});

  final MusicProvider provider;
  final MusicRoutingReason reason;

  /// Whether automatic routing produced this decision. [MusicRoutingReason]
  /// `picker` is the only reason the picker mode produces.
  bool get automatic => reason != MusicRoutingReason.picker;

  /// Matches the native line in `MediaButtonForegroundService`, so the Logs
  /// screen reads the same whichever side routed the like.
  String get logLine =>
      'Automatic routing -> ${provider.displayName} (${reason.label})';

  @override
  bool operator ==(Object other) =>
      other is MusicRoutingDecision &&
      other.provider == provider &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(provider, reason);

  @override
  String toString() => 'MusicRoutingDecision(${provider.id}, ${reason.name})';
}

/// What the native side knows about media sessions right now.
///
/// Both facts need notification access; without it [playing] is empty and
/// [lastPlaying] is null, which is exactly the "automatic cannot answer" case.
class MusicSessionSnapshot {
  const MusicSessionSnapshot({
    this.playing = const <MusicProvider>[],
    this.lastPlaying,
  });

  /// Providers owning a `STATE_PLAYING` media session, without duplicates.
  final List<MusicProvider> playing;

  /// The provider whose session was playing most recently, across reboots of
  /// the listener; null when none has been seen.
  final MusicProvider? lastPlaying;

  /// Reads the `getMusicSessions` channel reply. Unknown provider ids are
  /// dropped rather than mapped onto the default, so a newer native build
  /// cannot silently route to Spotify.
  factory MusicSessionSnapshot.fromChannel(Map<String, dynamic> reply) {
    final playing = <MusicProvider>[];
    for (final id in (reply['playing'] as List<Object?>? ?? <Object?>[])) {
      final provider = _knownProvider(id);
      if (provider != null && !playing.contains(provider)) playing.add(provider);
    }
    return MusicSessionSnapshot(
      playing: playing,
      lastPlaying: _knownProvider(reply['lastPlaying']),
    );
  }

  static MusicProvider? _knownProvider(Object? id) {
    for (final provider in MusicProvider.values) {
      if (provider.id == id) return provider;
    }
    return null;
  }
}
