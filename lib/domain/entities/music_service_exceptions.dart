import 'music_provider.dart';

/// An error from a music service's HTTP API that carries a status code.
///
/// Implemented by each provider's API exception so presentation code can log
/// the HTTP code without depending on a specific provider's data layer.
abstract class MusicServiceHttpException implements Exception {
  int get statusCode;
}

/// The selected music service has no usable sign-in, so nothing was sent to
/// any service.
class MusicServiceNotConnectedException implements Exception {
  const MusicServiceNotConnectedException(this.provider);

  final MusicProvider provider;

  @override
  String toString() => '${provider.displayName} not connected';
}
