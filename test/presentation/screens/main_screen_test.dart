import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';
import 'package:like_spotify_mobile_app/presentation/screens/main_screen.dart';

import '../../helpers/screen_harness.dart';

void main() {
  testWidgets('says nothing about a queue while there is none', (tester) async {
    await tester.pumpWidget(hostScreen(const MainScreen()));
    await tester.pumpAndSettle();

    expect(find.textContaining('queued'), findsNothing);
  });

  testWidgets('promises an online retry for a queue on Spotify', (tester) async {
    await tester.pumpWidget(
      hostScreen(const MainScreen(), pendingLikes: 2),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('2 like(s) queued — will retry when online'),
      findsOneWidget,
    );
  });

  testWidgets('points a queue at Spotify while YouTube Music is selected',
      (tester) async {
    await tester.pumpWidget(
      hostScreen(
        const MainScreen(),
        provider: MusicProvider.ytmusic,
        pendingLikes: 2,
      ),
    );
    await tester.pumpAndSettle();

    // YouTube Music never queues and never replays the queue, so promising a
    // retry "when online" here would be a retry that cannot happen.
    expect(find.textContaining('will retry when online'), findsNothing);
    expect(
      find.text(
        '2 Spotify like(s) queued — will retry when Spotify is selected',
      ),
      findsOneWidget,
    );
  });

  testWidgets('does not say ACTIVE while nothing can reach the trigger',
      (tester) async {
    await tester.pumpWidget(
      hostScreen(
        const MainScreen(),
        serviceEnabled: true,
        notificationAccess: false,
      ),
    );
    await tester.pumpAndSettle();

    // The service is running, but without notification access a pause-play
    // produces nothing at all — the silence #153 was filed about.
    expect(find.text('ACTIVE'), findsNothing);
    expect(find.text('NOT LISTENING'), findsOneWidget);
    expect(find.text('Notification access is off'), findsOneWidget);
    expect(find.text('Grant notification access'), findsOneWidget);
  });

  testWidgets('warns about the missing grant before the service is even on',
      (tester) async {
    await tester.pumpWidget(
      hostScreen(const MainScreen(), notificationAccess: false),
    );
    await tester.pumpAndSettle();

    expect(find.text('INACTIVE'), findsOneWidget);
    expect(find.text('Notification access is off'), findsOneWidget);
  });

  testWidgets('says ACTIVE, and warns about nothing, once the grant is there',
      (tester) async {
    await tester.pumpWidget(
      hostScreen(const MainScreen(), serviceEnabled: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('ACTIVE'), findsOneWidget);
    expect(find.text('Notification access is off'), findsNothing);
  });
}
