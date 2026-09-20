import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/entities/music_provider.dart';
import '../state/app_providers.dart';
import '../state/ytmusic_sign_in_controller.dart';

class ConnectedServicesScreen extends ConsumerWidget {
  const ConnectedServicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);
    final provider = state.musicProvider;
    final name = provider.displayName;
    final isYouTubeMusic = provider == MusicProvider.ytmusic;
    final signInBusy = isYouTubeMusic &&
        ref.watch(youTubeMusicSignInControllerProvider.select((s) => s.busy));
    final accountId = state.authState.connected ? state.authState.accountId : null;

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
            onSelectionChanged: signInBusy
                ? null
                : (selection) => controller.selectMusicProvider(selection.single),
          ),
          const SizedBox(height: 8),
          const Text(
            'Likes from your media-button pattern go to this service.',
          ),
          const SizedBox(height: 20),
          Text('$name installed: ${state.musicAppInstalled ? 'Yes' : 'No'}'),
          const SizedBox(height: 8),
          Text('$name connected: ${state.authState.connected ? 'Yes' : 'No'}'),
          if (accountId != null && accountId.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            SelectableText('Account: $accountId'),
          ],
          if (isYouTubeMusic) ...<Widget>[
            const SizedBox(height: 20),
            const _YouTubeMusicSignIn(),
          ],
          const SizedBox(height: 20),
          Row(
            children: <Widget>[
              if (!isYouTubeMusic) ...<Widget>[
                FilledButton(
                  onPressed: controller.connectMusicService,
                  child: Text('Connect $name'),
                ),
                const SizedBox(width: 8),
              ],
              OutlinedButton(
                onPressed: signInBusy ? null : controller.disconnectMusicService,
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

/// Client ID/secret entry plus Google's device-code sign-in.
class _YouTubeMusicSignIn extends ConsumerStatefulWidget {
  const _YouTubeMusicSignIn();

  @override
  ConsumerState<_YouTubeMusicSignIn> createState() => _YouTubeMusicSignInState();
}

class _YouTubeMusicSignInState extends ConsumerState<_YouTubeMusicSignIn> {
  /// Where the "TVs and Limited Input devices" client is actually created.
  static const _credentialsConsoleUrl =
      'https://console.cloud.google.com/apis/credentials';

  /// The README's *YouTube Music (Android)* section — the long form of setup,
  /// so this card does not have to repeat it.
  static const _setupGuideUrl =
      'https://github.com/Osasuwu/like-current-song#youtube-music-android';

  final _clientId = TextEditingController();
  final _clientSecret = TextEditingController();
  bool _prefilled = false;
  bool _secretHidden = true;

  @override
  void dispose() {
    _clientId.dispose();
    _clientSecret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final signIn = ref.watch(youTubeMusicSignInControllerProvider);
    final controller = ref.read(youTubeMusicSignInControllerProvider.notifier);
    final theme = Theme.of(context);

    final saved = signIn.credentials;
    if (!_prefilled && saved != null) {
      _prefilled = true;
      _clientId.text = saved.clientId;
      _clientSecret.text = saved.clientSecret;
    }

    final prompt = signIn.prompt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Google sign-in', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text(
          'Uses an OAuth client from your own Google Cloud project, of type '
          '"TVs and Limited Input devices", with YouTube Data API v3 enabled.',
        ),
        Wrap(
          spacing: 8,
          children: <Widget>[
            TextButton.icon(
              onPressed: () => _openUrl(_credentialsConsoleUrl),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Google Cloud credentials'),
            ),
            TextButton.icon(
              onPressed: () => _openUrl(_setupGuideUrl),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Setup steps'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _clientId,
          enabled: !signIn.busy,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'Client ID',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _clientSecret,
          enabled: !signIn.busy,
          obscureText: _secretHidden,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Client secret',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: _secretHidden ? 'Show secret' : 'Hide secret',
              icon: Icon(
                _secretHidden ? Icons.visibility : Icons.visibility_off,
              ),
              onPressed: () => setState(() => _secretHidden = !_secretHidden),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            OutlinedButton(
              onPressed: signIn.busy
                  ? null
                  : () => controller.saveCredentials(
                        clientId: _clientId.text,
                        clientSecret: _clientSecret.text,
                      ),
              child: const Text('Save credentials'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: signIn.busy || !signIn.hasCredentials
                  ? null
                  : controller.connect,
              child: const Text('Connect YouTube Music'),
            ),
          ],
        ),
        if (!signIn.hasCredentials) ...<Widget>[
          const SizedBox(height: 4),
          const Text(
            'Connect turns on once the client ID and secret are saved.',
          ),
        ],
        if (signIn.phase == DeviceSignInPhase.idle) ...<Widget>[
          const SizedBox(height: 4),
          const Text('The sign-in code appears after you tap Connect.'),
        ],
        if (signIn.credentialsSaved) ...<Widget>[
          const SizedBox(height: 4),
          const Text('Credentials saved.'),
        ],
        if (signIn.phase == DeviceSignInPhase.requestingCode) ...<Widget>[
          const SizedBox(height: 16),
          const Row(
            children: <Widget>[
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 8),
              Text('Getting a sign-in code...'),
            ],
          ),
        ],
        if (prompt != null &&
            signIn.phase == DeviceSignInPhase.awaitingApproval) ...<Widget>[
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'On any device, open ${prompt.verificationUrl} and enter:',
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      SelectableText(
                        prompt.userCode,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontFamily: 'monospace',
                          letterSpacing: 2,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy code',
                        icon: const Icon(Icons.copy),
                        onPressed: () => _copyCode(prompt.userCode),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton.tonal(
                        onPressed: () => _openUrl(prompt.verificationUrl),
                        child: const Text('Open in browser'),
                      ),
                      TextButton(
                        onPressed: controller.cancel,
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Row(
                    children: <Widget>[
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Expanded(child: Text('Waiting for approval...')),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
        if (signIn.error != null) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            signIn.error!,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
      ],
    );
  }

  Future<void> _copyCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Code copied')),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    var opened = false;
    if (uri != null) {
      try {
        opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        opened = false;
      }
    }
    if (opened || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not open a browser. Go to $url manually.')),
    );
  }
}
