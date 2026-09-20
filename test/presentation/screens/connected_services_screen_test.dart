import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/device_sign_in.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';
import 'package:like_spotify_mobile_app/presentation/screens/connected_services_screen.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/app_controller_harness.dart';

void main() {
  setUpAll(registerAppControllerFallbacks);

  setUp(silenceConnectivityChannel);

  /// Shows the screen on [harness]'s mocks. The surface is made tall enough
  /// for the whole list, so nothing under test is skipped by the [ListView].
  Future<void> pumpScreen(
    WidgetTester tester,
    AppControllerHarness harness,
  ) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: harness.overrides,
        child: const MaterialApp(home: ConnectedServicesScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  SegmentedButton<MusicProvider> picker(WidgetTester tester) =>
      tester.widget<SegmentedButton<MusicProvider>>(
        find.byType(SegmentedButton<MusicProvider>),
      );

  testWidgets('offers every music service, in MusicProvider order',
      (tester) async {
    await pumpScreen(tester, AppControllerHarness());

    final segments = picker(tester).segments;
    expect(
      segments.map((s) => s.value),
      MusicProvider.values,
      reason: 'a new provider must show up without touching the screen',
    );
    expect(
      segments.map((s) => (s.label! as Text).data),
      <String>['Spotify', 'YouTube Music'],
    );
    expect(picker(tester).selected, <MusicProvider>{MusicProvider.spotify});
  });

  testWidgets('Spotify gets its OAuth connect button and the client-id note',
      (tester) async {
    await pumpScreen(tester, AppControllerHarness());

    expect(
      find.widgetWithText(FilledButton, 'Connect Spotify'),
      findsOneWidget,
    );
    expect(find.textContaining('SPOTIFY_CLIENT_ID'), findsOneWidget);
    expect(find.text('Google sign-in'), findsNothing);
  });

  testWidgets('YouTube Music replaces both with the device-code block',
      (tester) async {
    final harness = AppControllerHarness(selected: MusicProvider.ytmusic);
    when(() => harness.signIn.loadClientCredentials()).thenAnswer(
      (_) async =>
          const OAuthClientCredentials(clientId: 'cid', clientSecret: 'secret'),
    );
    when(() => harness.signIn.startSignIn()).thenThrow(
      const DeviceSignInException(
        DeviceSignInFailure.network,
        'Could not reach Google.',
      ),
    );

    await pumpScreen(tester, harness);

    // Spotify's OAuth pieces are gone...
    expect(find.textContaining('SPOTIFY_CLIENT_ID'), findsNothing);
    // ...and the device flow is in their place.
    expect(find.text('Google sign-in'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Client ID'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Client secret'), findsOneWidget);

    // The one 'Connect YouTube Music' button is the device-code one: it must
    // start the device flow, never the OAuth connect Spotify's button uses.
    final connect = find.widgetWithText(FilledButton, 'Connect YouTube Music');
    expect(connect, findsOneWidget);
    await tester.tap(connect);
    await tester.pumpAndSettle();

    verify(() => harness.signIn.startSignIn()).called(1);
    verifyNever(() => harness.ytmusic.connect());
  });

  testWidgets('picking a service persists it and tells the native listener',
      (tester) async {
    final harness = AppControllerHarness();
    await pumpScreen(tester, harness);

    await tester.tap(find.text('YouTube Music'));
    await tester.pumpAndSettle();

    expect(picker(tester).selected, <MusicProvider>{MusicProvider.ytmusic});
    verify(() => harness.settings.saveMusicProvider(MusicProvider.ytmusic))
        .called(1);
    verify(() => harness.platform.updateMusicProvider(MusicProvider.ytmusic))
        .called(1);
  });
}
