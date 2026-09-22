import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/like_destination.dart';
import 'package:like_spotify_mobile_app/domain/entities/music_provider.dart';
import 'package:like_spotify_mobile_app/presentation/widgets/like_destination_section.dart';

/// Hosts [LikeDestinationSection] the way the trigger settings screen does:
/// the selected destination lives in the parent, the name uses its controller.
class _Host extends StatefulWidget {
  const _Host({
    required this.destination,
    this.musicProvider = MusicProvider.spotify,
    this.playlistName = '',
  });

  final LikeDestination destination;
  final MusicProvider musicProvider;
  final String playlistName;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late LikeDestination destination = widget.destination;
  late final name = TextEditingController(text: widget.playlistName);

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: ListView(
          children: <Widget>[
            LikeDestinationSection(
              musicProvider: widget.musicProvider,
              destination: destination,
              onDestinationChanged: (value) =>
                  setState(() => destination = value),
              playlistName: name,
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  const playlistField = Key('like_destination_playlist_name');
  const perServiceNote = Key('like_destination_per_service_note');
  const quotaNote = Key('like_destination_quota_note');

  testWidgets('is a core like setting, always on screen', (tester) async {
    await tester.pumpWidget(const _Host(destination: LikeDestination.native));

    expect(find.byKey(const Key('like_destination_section')), findsOneWidget);
    expect(find.text('Where likes go'), findsOneWidget);
    for (final option in LikeDestination.values) {
      expect(find.text(option.displayName), findsOneWidget);
    }
  });

  testWidgets('asks for no playlist name when likes go to liked songs',
      (tester) async {
    await tester.pumpWidget(const _Host(destination: LikeDestination.native));

    expect(find.byKey(playlistField), findsNothing);
    expect(find.byKey(perServiceNote), findsNothing);
    expect(find.byKey(quotaNote), findsNothing);
  });

  testWidgets('asks for a playlist name once a playlist is chosen',
      (tester) async {
    await tester.pumpWidget(const _Host(destination: LikeDestination.native));

    await tester.tap(find.text(LikeDestination.playlist.displayName));
    await tester.pumpAndSettle();

    expect(find.byKey(playlistField), findsOneWidget);
    // The one surprise of a global setting: the name is matched per service.
    expect(find.byKey(perServiceNote), findsOneWidget);
  });

  testWidgets('keeps the field for both', (tester) async {
    await tester.pumpWidget(const _Host(
      destination: LikeDestination.both,
      playlistName: 'Trigger likes',
    ));

    expect(
      tester.widget<TextField>(find.byKey(playlistField)).controller?.text,
      'Trigger likes',
    );
  });

  testWidgets('warns about YouTube Music quota, and only there', (tester) async {
    await tester.pumpWidget(const _Host(
      destination: LikeDestination.playlist,
      musicProvider: MusicProvider.ytmusic,
    ));
    expect(find.byKey(quotaNote), findsOneWidget);

    await tester.pumpWidget(const _Host(
      destination: LikeDestination.playlist,
      musicProvider: MusicProvider.spotify,
    ));
    expect(find.byKey(quotaNote), findsNothing);
  });
}
