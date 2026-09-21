import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';
import 'package:like_spotify_mobile_app/presentation/screens/permissions_screen.dart';

import '../../helpers/screen_harness.dart';

void main() {
  testWidgets('names Spotify as what internet access is for', (tester) async {
    await tester.pumpWidget(hostScreen(const PermissionsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('• Internet access for Spotify'), findsOneWidget);
  });

  testWidgets('names YouTube Music when it is the selected service',
      (tester) async {
    await tester.pumpWidget(
      hostScreen(const PermissionsScreen(), provider: MusicProvider.ytmusic),
    );
    await tester.pumpAndSettle();

    expect(find.text('• Internet access for YouTube Music'), findsOneWidget);
    expect(find.textContaining('Spotify'), findsNothing);
  });

  testWidgets('calls notification access required, never a fallback',
      (tester) async {
    await tester.pumpWidget(hostScreen(const PermissionsScreen()));
    await tester.pumpAndSettle();

    // It is the only way a headset press reaches the app (#153): calling it a
    // fallback is what made a user leave it off and get nothing at all.
    expect(find.textContaining('fallback'), findsNothing);
    expect(
      find.text('• Notification access (required): Enabled'),
      findsOneWidget,
    );
    expect(
      find.text('Open notification access (required)'),
      findsOneWidget,
    );
  });

  testWidgets('says why the grant is what the trigger runs on', (tester) async {
    await tester.pumpWidget(
      hostScreen(const PermissionsScreen(), notificationAccess: false),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('• Notification access (required): Disabled'),
      findsOneWidget,
    );
    expect(
      find.textContaining('goes to the music app, not to us'),
      findsOneWidget,
    );
  });
}
