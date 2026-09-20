import 'package:flutter/material.dart';

import '../../core/app_constants.dart';
import '../../domain/entities/music_provider.dart';

/// Collapsed "Extra actions" block of the trigger settings.
///
/// Groups the optional things that can happen after a like: removing the song
/// from an archive playlist, promoting it to a best-of playlist, and following
/// the artist. None of them is needed for liking itself, so the section starts
/// collapsed and every action is opt-in. The wording is deliberately
/// service-neutral so the section looks the same whichever music service is
/// selected — bar the YouTube Music quota note, which is a real limit users
/// hit.
///
/// The widget is stateless: the owning screen keeps the switch values and the
/// text controllers and receives changes through the callbacks.
class ExtraActionsSection extends StatelessWidget {
  const ExtraActionsSection({
    super.key,
    required this.musicProvider,
    required this.archiveRemoveEnabled,
    required this.onArchiveRemoveChanged,
    required this.archivePlaylistName,
    required this.bestOfEnabled,
    required this.onBestOfChanged,
    required this.bestOfPlaylistName,
    required this.bestOfThreshold,
    required this.followArtistEnabled,
    required this.onFollowArtistChanged,
    required this.followArtistThreshold,
  });

  /// The selected service; only YouTube Music charges API quota per action.
  final MusicProvider musicProvider;

  final bool archiveRemoveEnabled;
  final ValueChanged<bool> onArchiveRemoveChanged;
  final TextEditingController archivePlaylistName;

  final bool bestOfEnabled;
  final ValueChanged<bool> onBestOfChanged;
  final TextEditingController bestOfPlaylistName;
  final TextEditingController bestOfThreshold;

  final bool followArtistEnabled;
  final ValueChanged<bool> onFollowArtistChanged;
  final TextEditingController followArtistThreshold;

  int get _enabledCount =>
      <bool>[archiveRemoveEnabled, bestOfEnabled, followArtistEnabled]
          .where((enabled) => enabled)
          .length;

  @override
  Widget build(BuildContext context) {
    final count = _enabledCount;
    return ExpansionTile(
      key: const Key('extra_actions_section'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      title: const Text('Extra actions'),
      subtitle: Text(
        count == 0 ? 'Optional, all off' : '$count of 3 on',
      ),
      children: <Widget>[
        if (musicProvider == MusicProvider.ytmusic)
          Padding(
            key: const Key('extra_actions_quota_note'),
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'On YouTube Music each of these costs about 50 of the 10,000 '
              'API units Google grants a day. Liking itself is free.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        SwitchListTile(
          key: const Key('extra_action_archive_remove'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Remove from archive playlist'),
          subtitle: const Text(
            'Takes a liked song out of this playlist. Enter the playlist name.',
          ),
          value: archiveRemoveEnabled,
          onChanged: onArchiveRemoveChanged,
        ),
        TextField(
          key: const Key('extra_action_archive_playlist_name'),
          controller: archivePlaylistName,
          enabled: archiveRemoveEnabled,
          decoration: const InputDecoration(
            labelText: 'Archive playlist name',
            hintText: 'e.g. ${AppConstants.legacyArchivePlaylistName}',
          ),
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          key: const Key('extra_action_best_of'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Promote to best-of playlist'),
          subtitle: const Text(
            'Adds a song you keep liking to this playlist. Enter the name and '
            'how many likes it takes.',
          ),
          value: bestOfEnabled,
          onChanged: onBestOfChanged,
        ),
        TextField(
          key: const Key('extra_action_best_of_playlist_name'),
          controller: bestOfPlaylistName,
          enabled: bestOfEnabled,
          decoration: const InputDecoration(
            labelText: 'Best-of playlist name',
            hintText: 'e.g. Best of the best',
          ),
        ),
        TextField(
          key: const Key('extra_action_best_of_threshold'),
          controller: bestOfThreshold,
          enabled: bestOfEnabled,
          decoration: const InputDecoration(
            labelText: 'Likes needed',
            hintText: '${AppConstants.defaultBestOfThreshold}',
          ),
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          key: const Key('extra_action_follow_artist'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Auto-follow artist'),
          subtitle: const Text(
            'Follows an artist once you have liked this many of their songs.',
          ),
          value: followArtistEnabled,
          onChanged: onFollowArtistChanged,
        ),
        TextField(
          key: const Key('extra_action_follow_artist_threshold'),
          controller: followArtistThreshold,
          enabled: followArtistEnabled,
          decoration: const InputDecoration(
            labelText: 'Liked songs needed',
            hintText: '${AppConstants.defaultFollowArtistThreshold}',
          ),
          keyboardType: TextInputType.number,
        ),
      ],
    );
  }
}
