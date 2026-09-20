import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/device_sign_in.dart';
import '../../domain/repositories/device_sign_in_repository.dart';

enum DeviceSignInPhase {
  /// Nothing in progress.
  idle,

  /// Asking Google for a code.
  requestingCode,

  /// Showing the code; waiting for the user to approve it.
  awaitingApproval,
}

class YouTubeMusicSignInState {
  const YouTubeMusicSignInState({
    this.credentials,
    this.phase = DeviceSignInPhase.idle,
    this.prompt,
    this.error,
    this.credentialsSaved = false,
  });

  final OAuthClientCredentials? credentials;
  final DeviceSignInPhase phase;

  /// The code to show while [phase] is [DeviceSignInPhase.awaitingApproval].
  final DeviceSignInPrompt? prompt;

  /// Last failure, ready to show as-is.
  final String? error;

  /// True right after the user saved new credentials (for a confirmation).
  final bool credentialsSaved;

  bool get hasCredentials => credentials?.isComplete ?? false;
  bool get busy => phase != DeviceSignInPhase.idle;

  YouTubeMusicSignInState copyWith({
    OAuthClientCredentials? credentials,
    DeviceSignInPhase? phase,
    DeviceSignInPrompt? prompt,
    bool clearPrompt = false,
    String? error,
    bool clearError = false,
    bool? credentialsSaved,
  }) {
    return YouTubeMusicSignInState(
      credentials: credentials ?? this.credentials,
      phase: phase ?? this.phase,
      prompt: clearPrompt ? null : (prompt ?? this.prompt),
      error: clearError ? null : (error ?? this.error),
      credentialsSaved: credentialsSaved ?? this.credentialsSaved,
    );
  }
}

/// Drives YouTube Music's Google device-code sign-in on Connected services.
class YouTubeMusicSignInController
    extends StateNotifier<YouTubeMusicSignInState> {
  YouTubeMusicSignInController({
    required DeviceSignInRepository signInRepository,
    required Future<void> Function() onSignedIn,
  })  : _repository = signInRepository,
        _onSignedIn = onSignedIn,
        super(const YouTubeMusicSignInState());

  final DeviceSignInRepository _repository;
  final Future<void> Function() _onSignedIn;

  Future<void> load() async {
    try {
      final credentials = await _repository.loadClientCredentials();
      if (!mounted) return;
      state = state.copyWith(credentials: credentials);
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(error: 'Could not read saved credentials: $error');
    }
  }

  Future<void> saveCredentials({
    required String clientId,
    required String clientSecret,
  }) async {
    final credentials = OAuthClientCredentials(
      clientId: clientId.trim(),
      clientSecret: clientSecret.trim(),
    );
    if (!credentials.isComplete) {
      state = state.copyWith(
        error: 'Enter both the client ID and the client secret.',
        credentialsSaved: false,
      );
      return;
    }
    try {
      await _repository.saveClientCredentials(credentials);
      if (!mounted) return;
      state = state.copyWith(
        credentials: credentials,
        credentialsSaved: true,
        clearError: true,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(error: 'Could not save credentials: $error');
    }
  }

  /// Runs the whole device flow: get a code, show it, wait for approval.
  /// Every failure ends in [YouTubeMusicSignInState.error], never a throw.
  Future<void> connect() async {
    if (state.busy) return;
    state = state.copyWith(
      phase: DeviceSignInPhase.requestingCode,
      clearPrompt: true,
      clearError: true,
      credentialsSaved: false,
    );
    try {
      final prompt = await _repository.startSignIn();
      if (!mounted) return;
      state = state.copyWith(
        phase: DeviceSignInPhase.awaitingApproval,
        prompt: prompt,
      );
      await _repository.waitForApproval(prompt);
      if (!mounted) return;
      state = state.copyWith(phase: DeviceSignInPhase.idle, clearPrompt: true);
      await _onSignedIn();
    } on DeviceSignInException catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        phase: DeviceSignInPhase.idle,
        clearPrompt: true,
        error: e.failure == DeviceSignInFailure.cancelled ? null : e.message,
        clearError: e.failure == DeviceSignInFailure.cancelled,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        phase: DeviceSignInPhase.idle,
        clearPrompt: true,
        error: 'Sign-in failed: $error',
      );
    }
  }

  void cancel() => _repository.cancelSignIn();

  @override
  void dispose() {
    // Leaving the screen stops polling; the code can't be seen any more.
    _repository.cancelSignIn();
    super.dispose();
  }
}
