import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/like_result.dart';
import '../../domain/entities/music_provider.dart';
import '../state/app_providers.dart';
import '../widgets/app_drawer.dart';

class MainScreen extends ConsumerWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Like Current Song')),
      drawer: const AppDrawer(),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Transform.scale(
                scale: 1.6,
                child: Switch(
                  value: state.serviceEnabled,
                  onChanged: (value) => controller.toggleService(value),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                state.serviceEnabled
                    ? (state.notificationListenerEnabled
                        ? 'ACTIVE'
                        : 'NOT LISTENING')
                    : 'INACTIVE',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      color: state.serviceEnabled && !state.triggerCanFire
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
              ),
              if (!state.notificationListenerEnabled) ...<Widget>[
                const SizedBox(height: 16),
                const _NotificationAccessWarning(),
              ],
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: state.liking ? null : controller.likeCurrentTrackNow,
                child: state.liking
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Like current track now'),
              ),
              if (state.pendingLikesCount > 0) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  // The queue is Spotify-only — YouTube Music likes are never
                  // queued — so under YouTube Music it waits for the switch back.
                  state.musicProvider == MusicProvider.spotify
                      ? '${state.pendingLikesCount} like(s) queued — will retry when online'
                      : '${state.pendingLikesCount} Spotify like(s) queued — will retry when Spotify is selected',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                ),
              ],
              if (state.lastLikeResult != null) ...<Widget>[
                const SizedBox(height: 16),
                _LikeResultCard(result: state.lastLikeResult!),
              ],
              if (state.lastError != null) ...<Widget>[
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    state.lastError!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Says, where it cannot be missed, that the trigger has no way in.
///
/// Notification access is the whole mechanism — the media button goes to the
/// player, so the app watches the player's pause/play state instead. Without
/// the grant a pause-play produces nothing at all, not even a failed log line,
/// which is exactly what made #153 so hard to diagnose.
class _NotificationAccessWarning extends ConsumerWidget {
  const _NotificationAccessWarning();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(appControllerProvider.notifier);
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Card(
        color: theme.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.warning_amber_rounded,
                    color: theme.colorScheme.onErrorContainer,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Notification access is off',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'The headset button goes to the music app, not to us, so the '
                "trigger reads the player's pause/play state — and that needs "
                'notification access. Until you grant it, pause-play does '
                'nothing.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: <Widget>[
                  FilledButton(
                    onPressed: controller.openNotificationListenerSettings,
                    child: const Text('Grant notification access'),
                  ),
                  TextButton(
                    onPressed: controller.refreshNotificationListenerStatus,
                    child: const Text('Recheck'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LikeResultCard extends StatelessWidget {
  final LikeResult result;

  const _LikeResultCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.favorite, color: theme.colorScheme.primary, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      result.trackName,
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    'x${result.trackLikeCount}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
              if (result.addedToBest || result.removedFromArchive || result.followedArtistNames.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: <Widget>[
                    if (result.addedToBest)
                      _badge(context, 'Best', Icons.star),
                    if (result.removedFromArchive)
                      _badge(context, 'Archive cleaned', Icons.cleaning_services),
                    for (final name in result.followedArtistNames)
                      _badge(context, 'Followed $name', Icons.person_add),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _badge(BuildContext context, String label, IconData icon) {
    final theme = Theme.of(context);
    return Chip(
      avatar: Icon(icon, size: 14),
      label: Text(label, style: theme.textTheme.labelSmall),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
