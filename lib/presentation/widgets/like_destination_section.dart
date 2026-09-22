import 'package:flutter/material.dart';

import '../../domain/entities/like_destination.dart';
import '../../domain/entities/music_provider.dart';

/// "Where likes go" block of the trigger settings.
///
/// A core like setting, not an extra action: it changes what liking does
/// rather than adding something on top, so it sits with the other like
/// settings and is always visible.
///
/// The setting is global, not per service. The playlist is matched by name on
/// whichever service is selected, so the same name means a different playlist
/// on Spotify and on YouTube Music — the copy says so, because that is the one
/// surprise the choice can spring.
///
/// The widget is stateless: the owning screen keeps the selected destination
/// and the text controller and receives changes through the callback.
class LikeDestinationSection extends StatelessWidget {
  const LikeDestinationSection({
    super.key,
    required this.musicProvider,
    required this.destination,
    required this.onDestinationChanged,
    required this.playlistName,
  });

  /// The selected service; only YouTube Music charges API quota per action.
  final MusicProvider musicProvider;

  final LikeDestination destination;
  final ValueChanged<LikeDestination> onDestinationChanged;
  final TextEditingController playlistName;

  @override
  Widget build(BuildContext context) {
    final needsPlaylist = destination.addsToPlaylist;
    return Column(
      key: const Key('like_destination_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Where likes go', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'On YouTube Music, liked songs land in the same place as every video '
          'you have ever liked. A playlist of your own keeps them together.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        SegmentedButton<LikeDestination>(
          key: const Key('like_destination_choice'),
          segments: <ButtonSegment<LikeDestination>>[
            for (final option in LikeDestination.values)
              ButtonSegment<LikeDestination>(
                value: option,
                label: Text(option.displayName),
              ),
          ],
          selected: <LikeDestination>{destination},
          onSelectionChanged: (selection) => onDestinationChanged(selection.first),
        ),
        if (needsPlaylist) ...<Widget>[
          TextField(
            key: const Key('like_destination_playlist_name'),
            controller: playlistName,
            decoration: const InputDecoration(
              labelText: 'Like playlist name',
              hintText: 'e.g. Liked by trigger',
            ),
          ),
          Padding(
            key: const Key('like_destination_per_service_note'),
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'One name for every service. It is matched on whichever service '
              'the like goes to, and created there if it does not exist yet, so '
              'the same name means a separate playlist on each.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (musicProvider == MusicProvider.ytmusic)
            Padding(
              key: const Key('like_destination_quota_note'),
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'On YouTube Music a playlist add costs about 50 of the 10,000 '
                'API units Google grants a day, on every like. Liking itself is '
                'free, so this is the one setting that makes liking cost quota.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ],
    );
  }
}
