import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:like_spotify_mobile_app/domain/entities/rule_config.dart';
import 'package:like_spotify_mobile_app/presentation/widgets/extra_actions_section.dart';

/// Hosts [ExtraActionsSection] the way the trigger settings screen does:
/// switch state lives in the parent, fields use its controllers.
class _Host extends StatefulWidget {
  const _Host({required this.config});

  final RuleConfig config;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late bool archive = widget.config.archiveRemoveEnabled;
  late bool bestOf = widget.config.bestOfEnabled;
  late bool follow = widget.config.followArtistEnabled;
  late final archiveName =
      TextEditingController(text: widget.config.archivePlaylistName);
  late final bestOfName =
      TextEditingController(text: widget.config.bestOfPlaylistName);
  final bestOfThreshold = TextEditingController();
  final followThreshold = TextEditingController();

  @override
  void dispose() {
    archiveName.dispose();
    bestOfName.dispose();
    bestOfThreshold.dispose();
    followThreshold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: ListView(
          children: <Widget>[
            ExtraActionsSection(
              archiveRemoveEnabled: archive,
              onArchiveRemoveChanged: (v) => setState(() => archive = v),
              archivePlaylistName: archiveName,
              bestOfEnabled: bestOf,
              onBestOfChanged: (v) => setState(() => bestOf = v),
              bestOfPlaylistName: bestOfName,
              bestOfThreshold: bestOfThreshold,
              followArtistEnabled: follow,
              onFollowArtistChanged: (v) => setState(() => follow = v),
              followArtistThreshold: followThreshold,
            ),
          ],
        ),
      ),
    );
  }
}

bool _switchValue(WidgetTester tester, String key) =>
    tester.widget<SwitchListTile>(find.byKey(Key(key))).value;

TextField _field(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key)));

void main() {
  const actionTitles = <String>[
    'Remove from archive playlist',
    'Promote to best-of playlist',
    'Auto-follow artist',
  ];

  testWidgets('starts collapsed, hiding the three actions', (tester) async {
    await tester.pumpWidget(_Host(config: RuleConfig.defaults()));

    expect(find.text('Extra actions'), findsOneWidget);
    expect(find.text('Optional, all off'), findsOneWidget);
    for (final title in actionTitles) {
      expect(find.text(title), findsNothing);
    }
  });

  testWidgets('fresh-install defaults: all off, empty fields, a hint each',
      (tester) async {
    await tester.pumpWidget(_Host(config: RuleConfig.defaults()));
    await tester.tap(find.text('Extra actions'));
    await tester.pumpAndSettle();

    for (final title in actionTitles) {
      expect(find.text(title), findsOneWidget);
    }
    expect(_switchValue(tester, 'extra_action_archive_remove'), isFalse);
    expect(_switchValue(tester, 'extra_action_best_of'), isFalse);
    expect(_switchValue(tester, 'extra_action_follow_artist'), isFalse);

    for (final key in <String>[
      'extra_action_archive_playlist_name',
      'extra_action_best_of_playlist_name',
      'extra_action_best_of_threshold',
      'extra_action_follow_artist_threshold',
    ]) {
      final field = _field(tester, key);
      expect(field.controller!.text, isEmpty, reason: key);
      expect(field.enabled, isFalse, reason: '$key is disabled while off');
    }

    // Every action explains itself in its subtitle.
    for (final key in <String>[
      'extra_action_archive_remove',
      'extra_action_best_of',
      'extra_action_follow_artist',
    ]) {
      final tile = tester.widget<SwitchListTile>(find.byKey(Key(key)));
      expect(tile.subtitle, isA<Text>(), reason: key);
      expect((tile.subtitle! as Text).data, isNotEmpty, reason: key);
    }
  });

  testWidgets('switching an action on enables its fields and updates the summary',
      (tester) async {
    await tester.pumpWidget(_Host(config: RuleConfig.defaults()));
    await tester.tap(find.text('Extra actions'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('extra_action_best_of')));
    await tester.pumpAndSettle();

    expect(_switchValue(tester, 'extra_action_best_of'), isTrue);
    expect(_field(tester, 'extra_action_best_of_playlist_name').enabled, isTrue);
    expect(_field(tester, 'extra_action_best_of_threshold').enabled, isTrue);
    expect(_field(tester, 'extra_action_archive_playlist_name').enabled, isFalse);
    expect(find.text('1 of 3 on'), findsOneWidget);
  });

  testWidgets('shows saved values of an upgraded install', (tester) async {
    await tester.pumpWidget(_Host(config: RuleConfig.legacyDefaults()));
    await tester.tap(find.text('Extra actions'));
    await tester.pumpAndSettle();

    expect(find.text('3 of 3 on'), findsOneWidget);
    expect(_switchValue(tester, 'extra_action_archive_remove'), isTrue);
    expect(
      _field(tester, 'extra_action_archive_playlist_name').controller!.text,
      RuleConfig.legacyDefaults().archivePlaylistName,
    );
  });
}
