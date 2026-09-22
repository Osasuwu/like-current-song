import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_constants.dart';
import '../../domain/entities/like_destination.dart';
import '../../domain/entities/rule_config.dart';
import '../../domain/entities/trigger_config.dart';
import '../state/app_providers.dart';
import '../widgets/extra_actions_section.dart';
import '../widgets/like_destination_section.dart';
import '../widgets/screen_padding.dart';

/// Text for a threshold field: empty while it holds the default, so the field
/// shows the default as its hint instead of looking pre-filled.
String _thresholdText(int value, int defaultValue) =>
    value == defaultValue ? '' : value.toString();

/// Parses a threshold field; an empty or invalid entry means the default.
int _parseThreshold(String text, int defaultValue) =>
    int.tryParse(text.trim()) ?? defaultValue;

class TriggerConfigScreen extends ConsumerStatefulWidget {
  const TriggerConfigScreen({super.key});

  @override
  ConsumerState<TriggerConfigScreen> createState() => _TriggerConfigScreenState();
}

class _TriggerConfigScreenState extends ConsumerState<TriggerConfigScreen> {
  late TextEditingController _pattern;
  late TextEditingController _window;
  late TextEditingController _debounce;
  late TextEditingController _archivePlaylistName;
  late TextEditingController _bestPlaylistName;
  late TextEditingController _bestThreshold;
  late TextEditingController _followArtistThreshold;
  late TextEditingController _likeCooldownMinutes;
  late TextEditingController _likePlaylistName;

  late LikeDestination _likeDestination;
  late bool _archiveRemoveEnabled;
  late bool _bestEnabled;
  late bool _followArtistEnabled;
  late bool _likeCooldownEnabled;
  late int _feedbackVolume;

  @override
  void initState() {
    super.initState();
    final state = ref.read(appControllerProvider);
    final config = state.triggerConfig;
    final ruleConfig = state.ruleConfig;
    _pattern = TextEditingController(text: config.pattern);
    _window = TextEditingController(text: config.windowMs.toString());
    _debounce = TextEditingController(text: config.debounceMs.toString());
    _feedbackVolume = config.feedbackVolume;
    _archivePlaylistName = TextEditingController(text: ruleConfig.archivePlaylistName);
    _bestPlaylistName = TextEditingController(text: ruleConfig.bestPlaylistName);
    _bestThreshold = TextEditingController(
      text: _thresholdText(ruleConfig.bestThreshold, AppConstants.defaultBestThreshold),
    );
    _followArtistThreshold = TextEditingController(
      text: _thresholdText(
        ruleConfig.followArtistThreshold,
        AppConstants.defaultFollowArtistThreshold,
      ),
    );
    _likeCooldownMinutes = TextEditingController(text: ruleConfig.likeCooldownMinutes.toString());
    _likePlaylistName = TextEditingController(text: ruleConfig.likePlaylistName);
    _likeDestination = ruleConfig.likeDestination;
    _archiveRemoveEnabled = ruleConfig.archiveRemoveEnabled;
    _bestEnabled = ruleConfig.bestEnabled;
    _followArtistEnabled = ruleConfig.followArtistEnabled;
    _likeCooldownEnabled = ruleConfig.likeCooldownEnabled;
  }

  @override
  void dispose() {
    _pattern.dispose();
    _window.dispose();
    _debounce.dispose();
    _archivePlaylistName.dispose();
    _bestPlaylistName.dispose();
    _bestThreshold.dispose();
    _followArtistThreshold.dispose();
    _likeCooldownMinutes.dispose();
    _likePlaylistName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(appControllerProvider.notifier);
    // Only the selected service matters here; watching the whole state would
    // rebuild the form on every log line.
    final musicProvider =
        ref.watch(appControllerProvider.select((state) => state.musicProvider));

    return Scaffold(
      appBar: AppBar(title: const Text('Trigger configuration')),
      body: ListView(
        padding: scrollBodyPadding(context),
        children: <Widget>[
          const Text(
            'Pattern format: comma separated events using play/pause.\nDefault: pause,play in 1000ms.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pattern,
            decoration: const InputDecoration(labelText: 'Pattern'),
          ),
          TextField(
            controller: _window,
            decoration: const InputDecoration(labelText: 'Window (ms)'),
            keyboardType: TextInputType.number,
          ),
          TextField(
            controller: _debounce,
            decoration: const InputDecoration(labelText: 'Debounce (ms)'),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          Text('Feedback sound volume: $_feedbackVolume%'),
          Slider(
            value: _feedbackVolume.toDouble(),
            min: 0,
            max: 100,
            divisions: 20,
            label: '$_feedbackVolume%',
            onChanged: (value) => setState(() => _feedbackVolume = value.round()),
          ),
          const SizedBox(height: 20),
          const Divider(),
          LikeDestinationSection(
            musicProvider: musicProvider,
            destination: _likeDestination,
            onDestinationChanged: (value) => setState(() => _likeDestination = value),
            playlistName: _likePlaylistName,
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Like cooldown'),
            subtitle: const Text('Ignore accidental repeat-likes of the same track'),
            value: _likeCooldownEnabled,
            onChanged: (value) => setState(() => _likeCooldownEnabled = value),
          ),
          TextField(
            controller: _likeCooldownMinutes,
            enabled: _likeCooldownEnabled,
            decoration: const InputDecoration(labelText: 'Cooldown (minutes)'),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          ExtraActionsSection(
            musicProvider: musicProvider,
            archiveRemoveEnabled: _archiveRemoveEnabled,
            onArchiveRemoveChanged: (value) =>
                setState(() => _archiveRemoveEnabled = value),
            archivePlaylistName: _archivePlaylistName,
            bestEnabled: _bestEnabled,
            onBestChanged: (value) => setState(() => _bestEnabled = value),
            bestPlaylistName: _bestPlaylistName,
            bestThreshold: _bestThreshold,
            followArtistEnabled: _followArtistEnabled,
            onFollowArtistChanged: (value) =>
                setState(() => _followArtistEnabled = value),
            followArtistThreshold: _followArtistThreshold,
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () async {
              final config = TriggerConfig(
                pattern: _pattern.text.trim(),
                windowMs: int.tryParse(_window.text.trim()) ?? 1000,
                debounceMs: int.tryParse(_debounce.text.trim()) ?? 650,
                feedbackVolume: _feedbackVolume,
              );
              final ruleConfig = RuleConfig(
                archiveRemoveEnabled: _archiveRemoveEnabled,
                archivePlaylistName: _archivePlaylistName.text.trim(),
                bestEnabled: _bestEnabled,
                bestPlaylistName: _bestPlaylistName.text.trim(),
                bestThreshold: _parseThreshold(
                  _bestThreshold.text,
                  AppConstants.defaultBestThreshold,
                ),
                followArtistEnabled: _followArtistEnabled,
                followArtistThreshold: _parseThreshold(
                  _followArtistThreshold.text,
                  AppConstants.defaultFollowArtistThreshold,
                ),
                likeCooldownEnabled: _likeCooldownEnabled,
                likeCooldownMinutes:
                    int.tryParse(_likeCooldownMinutes.text.trim()) ??
                        AppConstants.defaultLikeCooldownMinutes,
                likeDestination: _likeDestination,
                likePlaylistName: _likePlaylistName.text.trim(),
              );
              await controller.saveTriggerConfig(config);
              if (!context.mounted) return;
              // A rejected trigger config stops the save here: carrying on
              // would let a successful rule save clear the error, and the
              // user would be told the trigger was saved when it was not.
              final triggerError = ref.read(appControllerProvider).lastError;
              if (triggerError != null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(triggerError)),
                );
                return;
              }
              await controller.saveRuleConfig(ruleConfig);
              if (!context.mounted) return;
              final error = ref.read(appControllerProvider).lastError;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(error ?? 'Trigger configuration saved'),
                ),
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
