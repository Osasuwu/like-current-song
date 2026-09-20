import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/device_sign_in.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_routing.dart';
import 'package:like_spotify_mobile_app/domain/entities/spotify_auth_state.dart';
import 'package:like_spotify_mobile_app/presentation/screens/connected_services_screen.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/app_controller_harness.dart';

void main() {
  setUpAll(() {
    registerAppControllerFallbacks();
    registerFallbackValue(
      const OAuthClientCredentials(clientId: '', clientSecret: ''),
    );
  });

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

  /// The URLs handed to url_launcher, in tap order. On the test host the
  /// plugin is the plain method channel, so this sees exactly the URL a
  /// device would be asked to open.
  List<String> captureLaunchedUrls() {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final launched = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'launch') {
        final args = call.arguments as Map<Object?, Object?>;
        launched.add(args['url']! as String);
      }
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    return launched;
  }

  /// The service picker. `null` is the Automatic segment — the absence of an
  /// explicit pick — which is why the generic is nullable.
  SegmentedButton<MusicProvider?> picker(WidgetTester tester) =>
      tester.widget<SegmentedButton<MusicProvider?>>(
        find.byType(SegmentedButton<MusicProvider?>),
      );

  /// Opens both gates automatic routing is behind: notification access, and
  /// two signed-in services to choose between.
  AppControllerHarness automaticReady({
    MusicProvider selected = MusicProvider.spotify,
  }) {
    final harness = AppControllerHarness(selected: selected);
    when(() => harness.platform.isNotificationListenerEnabled())
        .thenAnswer((_) async => true);
    for (final repository in <MusicProvider>[
      MusicProvider.spotify,
      MusicProvider.ytmusic,
    ]) {
      final mock = repository == MusicProvider.spotify
          ? harness.spotify
          : harness.ytmusic;
      when(mock.getAuthState).thenAnswer(
        (_) async => SpotifyAuthState(
          accessToken: 'token',
          refreshToken: null,
          expiresAt: null,
          connected: true,
          accountId: repository.id,
        ),
      );
    }
    return harness;
  }

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
    expect(picker(tester).selected, <MusicProvider?>{MusicProvider.spotify});
  });

  testWidgets('without notification access, Automatic is not on offer',
      (tester) async {
    // The harness leaves notification access off, as a fresh install has it.
    await pumpScreen(tester, AppControllerHarness());

    expect(picker(tester).segments.map((s) => s.value), MusicProvider.values);
    expect(find.text('Automatic'), findsNothing);
    expect(
      find.text('Automatic needs notification access to see what is playing.'),
      findsOneWidget,
      reason: 'a missing option with no reason given is just a missing option',
    );
  });

  testWidgets('with one service connected, Automatic is not on offer',
      (tester) async {
    final harness = AppControllerHarness();
    when(() => harness.platform.isNotificationListenerEnabled())
        .thenAnswer((_) async => true);
    when(harness.spotify.getAuthState).thenAnswer(
      (_) async => const SpotifyAuthState(
        accessToken: 'token',
        refreshToken: null,
        expiresAt: null,
        connected: true,
      ),
    );

    await pumpScreen(tester, harness);

    expect(find.text('Automatic'), findsNothing);
    expect(
      find.text('Automatic needs two connected services to choose between.'),
      findsOneWidget,
    );
  });

  testWidgets('with both gates open, Automatic joins the picker unselected',
      (tester) async {
    await pumpScreen(tester, automaticReady());

    expect(
      picker(tester).segments.map((s) => s.value),
      <MusicProvider?>[MusicProvider.spotify, MusicProvider.ytmusic, null],
      reason: 'Automatic is last: the explicit picks come first',
    );
    expect(
      picker(tester).selected,
      <MusicProvider?>{MusicProvider.spotify},
      reason: 'automatic is opt-in — offering it must not select it',
    );
    expect(find.textContaining('Automatic needs'), findsNothing);
  });

  testWidgets('choosing Automatic persists it and tells the native listener',
      (tester) async {
    final harness = automaticReady();
    await pumpScreen(tester, harness);

    await tester.tap(find.text('Automatic'));
    await tester.pumpAndSettle();

    expect(picker(tester).selected, <MusicProvider?>{null});
    expect(harness.routingMode, MusicRoutingMode.automatic);
    verify(() => harness.settings
        .saveMusicRoutingMode(MusicRoutingMode.automatic)).called(1);
    verify(() => harness.platform
        .updateMusicRoutingMode(MusicRoutingMode.automatic)).called(1);
    expect(
      find.textContaining('whichever connected service is playing'),
      findsOneWidget,
    );
  });

  testWidgets('picking a service again leaves Automatic', (tester) async {
    final harness = automaticReady();
    await pumpScreen(tester, harness);

    await tester.tap(find.text('Automatic'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spotify'));
    await tester.pumpAndSettle();

    expect(picker(tester).selected, <MusicProvider?>{MusicProvider.spotify});
    expect(harness.routingMode, MusicRoutingMode.picker);
    // Start-up pushes the stored mode too, so only the save is a clean count.
    verify(() =>
        harness.settings.saveMusicRoutingMode(MusicRoutingMode.picker))
        .called(1);
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

  testWidgets('YouTube Music setup is reachable from the phone, by link',
      (tester) async {
    final launched = captureLaunchedUrls();
    await pumpScreen(
      tester,
      AppControllerHarness(selected: MusicProvider.ytmusic),
    );

    // The two things the field labels cannot tell you.
    expect(find.textContaining('TVs and Limited Input devices'), findsOneWidget);
    expect(find.textContaining('YouTube Data API v3'), findsOneWidget);

    await tester.tap(find.text('Google Cloud credentials'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Setup steps'));
    await tester.pumpAndSettle();

    expect(
      launched,
      <String>[
        'https://console.cloud.google.com/apis/credentials',
        'https://github.com/Osasuwu/like-current-song#youtube-music-android',
      ],
      reason: 'a phone-only user has no other route to either page',
    );
  });

  testWidgets('the sign-in card says it is optional and what it costs',
      (tester) async {
    await pumpScreen(
      tester,
      AppControllerHarness(selected: MusicProvider.ytmusic),
    );

    // Sign-in buys the fallback and the counter; the thumbs-up needs neither.
    expect(find.textContaining('Optional'), findsOneWidget);
    // Staying in Testing is the only reachable status, and it expires weekly.
    expect(find.textContaining('Testing'), findsOneWidget);
    expect(find.textContaining('7 days'), findsOneWidget);
    // The secret cannot be downloaded again; the card says where a new one
    // comes from.
    expect(find.textContaining('Google Auth Platform'), findsOneWidget);
  });

  testWidgets('a disabled Connect says why, until the credentials are saved',
      (tester) async {
    const reason = 'Connect turns on once the client ID and secret are saved.';
    final harness = AppControllerHarness(selected: MusicProvider.ytmusic);
    when(() => harness.signIn.saveClientCredentials(any()))
        .thenAnswer((_) async {});

    await pumpScreen(tester, harness);

    FilledButton connect() => tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Connect YouTube Music'),
        );

    expect(connect().onPressed, isNull);
    expect(find.text(reason), findsOneWidget);
    // And where the code google.com/device asks for comes from.
    expect(
      find.text('The sign-in code appears after you tap Connect.'),
      findsOneWidget,
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Client ID'),
      'client-id',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Client secret'),
      'client-secret',
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Save credentials'));
    await tester.pumpAndSettle();

    expect(connect().onPressed, isNotNull);
    expect(
      find.text(reason),
      findsNothing,
      reason: 'the button works now, so the explanation is just noise',
    );
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
