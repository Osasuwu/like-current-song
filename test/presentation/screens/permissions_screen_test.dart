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
}
