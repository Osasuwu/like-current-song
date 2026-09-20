import '../entities/music_provider.dart';
import '../entities/music_routing.dart';

/// The rule that decides which music service a like goes to.
///
/// Separate from `MusicServiceRepository` because the presentation layer needs
/// two things the like path does not expose: which services are connected (to
/// decide whether automatic routing can be offered at all) and which service a
/// like actually went to (to log it).
abstract class MusicRoutingRepository {
  /// The services that are signed in right now. A service without tokens is
  /// never chosen automatically, however loudly it is playing.
  Future<Set<MusicProvider>> connectedProviders();

  /// Which service the next like goes to, and why. Cheap to call, but it
  /// touches the platform channel in automatic mode.
  Future<MusicRoutingDecision> resolveRouting();

  /// Called once per automatic decision, as the like is routed, so the log
  /// records what actually happened rather than a second, later guess.
  /// Decisions made by the picker are not reported.
  void Function(MusicRoutingDecision decision)? get onAutomaticRouting;
  set onAutomaticRouting(void Function(MusicRoutingDecision decision)? listener);
}
