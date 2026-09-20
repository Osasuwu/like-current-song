import '../entities/device_sign_in.dart';
import '../entities/spotify_auth_state.dart';

/// Something that signs in with the OAuth 2.0 device flow using a client the
/// user brings — YouTube Music, and the shared like counter's spreadsheet.
///
/// The flow has two steps so the UI can show the code in between:
/// [startSignIn] gets a code to show, [waitForApproval] polls until the user
/// approves it elsewhere. Both throw [DeviceSignInException] with a message
/// ready for the user.
abstract class DeviceSignInRepository {
  Future<OAuthClientCredentials?> loadClientCredentials();

  Future<void> saveClientCredentials(OAuthClientCredentials credentials);

  Future<DeviceSignInPrompt> startSignIn();

  /// Polls until [prompt] is approved, then stores the tokens and returns the
  /// connected state. Throws [DeviceSignInException] with
  /// [DeviceSignInFailure.cancelled] after [cancelSignIn].
  Future<SpotifyAuthState> waitForApproval(DeviceSignInPrompt prompt);

  /// Stops a running [waitForApproval]. No-op when none is running.
  void cancelSignIn();
}
