import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/device_sign_in.dart';
import 'package:like_spotify_mobile_app/domain/entities/spotify_auth_state.dart';
import 'package:like_spotify_mobile_app/domain/repositories/device_sign_in_repository.dart';
import 'package:like_spotify_mobile_app/presentation/state/device_sign_in_controller.dart';
import 'package:mocktail/mocktail.dart';

class MockDeviceSignInRepository extends Mock
    implements DeviceSignInRepository {}

void main() {
  final prompt = DeviceSignInPrompt(
    deviceCode: 'dev-1',
    userCode: 'ABCD-EFGH',
    verificationUrl: 'https://www.google.com/device',
    expiresAt: DateTime.utc(2030),
    pollInterval: const Duration(seconds: 5),
  );

  late MockDeviceSignInRepository repo;
  late int signedInCalls;
  late DeviceSignInController controller;

  setUpAll(() {
    registerFallbackValue(prompt);
    registerFallbackValue(
        const OAuthClientCredentials(clientId: '', clientSecret: ''));
  });

  setUp(() {
    repo = MockDeviceSignInRepository();
    signedInCalls = 0;
    controller = DeviceSignInController(
      signInRepository: repo,
      onSignedIn: () async => signedInCalls++,
    );
  });

  test('load exposes saved credentials', () async {
    when(() => repo.loadClientCredentials()).thenAnswer((_) async =>
        const OAuthClientCredentials(clientId: 'cid', clientSecret: 's'));

    await controller.load();

    expect(controller.state.hasCredentials, isTrue);
  });

  test('saveCredentials rejects a blank field without saving', () async {
    await controller.saveCredentials(clientId: 'cid', clientSecret: '  ');

    expect(controller.state.error, isNotNull);
    verifyNever(() => repo.saveClientCredentials(any()));
  });

  test('saveCredentials stores trimmed values', () async {
    when(() => repo.saveClientCredentials(any())).thenAnswer((_) async {});

    await controller.saveCredentials(clientId: ' cid ', clientSecret: ' s ');

    final saved = verify(() => repo.saveClientCredentials(captureAny()))
        .captured
        .single as OAuthClientCredentials;
    expect(saved.clientId, 'cid');
    expect(saved.clientSecret, 's');
    expect(controller.state.credentialsSaved, isTrue);
  });

  test('connect shows the code, then reports success', () async {
    final approval = Completer<SpotifyAuthState>();
    when(() => repo.startSignIn()).thenAnswer((_) async => prompt);
    when(() => repo.waitForApproval(any())).thenAnswer((_) => approval.future);

    final done = controller.connect();
    await Future<void>.delayed(Duration.zero);

    expect(controller.state.phase, DeviceSignInPhase.awaitingApproval);
    expect(controller.state.prompt?.userCode, 'ABCD-EFGH');

    approval.complete(const SpotifyAuthState(
      accessToken: 'at',
      refreshToken: 'rt',
      expiresAt: null,
      connected: true,
    ));
    await done;

    expect(controller.state.phase, DeviceSignInPhase.idle);
    expect(controller.state.prompt, isNull);
    expect(controller.state.error, isNull);
    expect(signedInCalls, 1);
  });

  test('a readable failure ends in error, not a throw', () async {
    when(() => repo.startSignIn()).thenAnswer((_) async => prompt);
    when(() => repo.waitForApproval(any())).thenThrow(
      const DeviceSignInException(DeviceSignInFailure.denied, 'Declined.'),
    );

    await controller.connect();

    expect(controller.state.phase, DeviceSignInPhase.idle);
    expect(controller.state.error, 'Declined.');
    expect(signedInCalls, 0);
  });

  test('cancel returns to idle without an error', () async {
    when(() => repo.startSignIn()).thenAnswer((_) async => prompt);
    when(() => repo.waitForApproval(any())).thenThrow(
      const DeviceSignInException(
          DeviceSignInFailure.cancelled, 'Sign-in cancelled.'),
    );

    await controller.connect();

    expect(controller.state.phase, DeviceSignInPhase.idle);
    expect(controller.state.error, isNull);
  });

  test('an unexpected error is caught', () async {
    when(() => repo.startSignIn()).thenThrow(StateError('boom'));

    await controller.connect();

    expect(controller.state.phase, DeviceSignInPhase.idle);
    expect(controller.state.error, contains('boom'));
  });

  test('dispose cancels a running sign-in', () {
    controller.dispose();

    verify(() => repo.cancelSignIn()).called(1);
  });
}
