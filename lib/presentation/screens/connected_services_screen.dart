import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/music_provider.dart';
import '../state/app_providers.dart';

class ConnectedServicesScreen extends ConsumerWidget {
  const ConnectedServicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);
    final provider = state.musicProvider;
    final name = provider.displayName;
    // YouTube Music sign-in is not available on Android yet.
    final canConnect = provider == MusicProvider.spotify;

    return Scaffold(
      appBar: AppBar(title: const Text('Connected services')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text('Music service', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<MusicProvider>(
            segments: <ButtonSegment<MusicProvider>>[
              for (final p in MusicProvider.values)
                ButtonSegment<MusicProvider>(
                  value: p,
                  label: Text(p.displayName),
                ),
            ],
            selected: <MusicProvider>{provider},
            onSelectionChanged: (selection) =>
                controller.selectMusicProvider(selection.single),
          ),
          const SizedBox(height: 8),
          const Text(
            'Likes from your media-button pattern go to this service.',
          ),
          const SizedBox(height: 20),
          Text('$name installed: ${state.musicAppInstalled ? 'Yes' : 'No'}'),
          const SizedBox(height: 8),
          Text('$name connected: ${state.authState.connected ? 'Yes' : 'No'}'),
          if (!canConnect) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '$name sign-in is coming in a later release. Until then, '
              'likes are skipped and logged as "$name not connected".',
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: <Widget>[
              FilledButton(
                onPressed: canConnect ? controller.connectMusicService : null,
                child: Text('Connect $name'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: controller.disconnectMusicService,
                child: const Text('Disconnect'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: controller.refreshBatteryOptimizationStatus,
              child: const Text('Refresh status'),
            ),
          ),
          if (provider == MusicProvider.spotify) ...<Widget>[
            const SizedBox(height: 20),
            const Text(
              'OAuth note: provide SPOTIFY_CLIENT_ID at build/run time using --dart-define.',
            ),
          ],
        ],
      ),
    );
  }
}
