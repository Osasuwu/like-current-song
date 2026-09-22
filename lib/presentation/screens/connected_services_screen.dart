import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_constants.dart';
import '../../domain/entities/music_provider.dart';
import '../../domain/entities/music_routing.dart';
import '../state/app_providers.dart';
import '../state/device_sign_in_controller.dart';
import '../state/service_credentials_controller.dart';
import '../widgets/screen_padding.dart';

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
    final hasSpotifyClientId = ref.watch(
      serviceCredentialsControllerProvider.select((s) => s.hasSpotifyClientId),
    );
    // Automatic is offered only while it can be honoured; if it was on and the
    // gate closed, the controller falls back to the picker, so showing the
    // picked service here matches where a like would actually go.
    final automaticOffered = state.canRouteAutomatically;
    final automatic =
        automaticOffered && state.musicRoutingMode == MusicRoutingMode.automatic;
    final blockedReason = state.automaticRoutingBlockedReason;
    // Automatic hides which service is picked, but everything below this line
    // is still that service's — sign-in state, credentials, connect and
    // disconnect all stay on the pick (see `ActiveMusicServiceRepository`).
    // Without a name on the section the fields read as leftovers from before
    // the switch.
    final others = MusicProvider.values
        .where((p) => p != provider)
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(title: const Text('Connected services')),
      body: ListView(
        padding: scrollBodyPadding(context),
        children: <Widget>[
          Text('Music service', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          // `null` is Automatic: the absence of an explicit pick.
          SegmentedButton<MusicProvider?>(
            segments: <ButtonSegment<MusicProvider?>>[
              for (final p in MusicProvider.values)
                ButtonSegment<MusicProvider?>(
                  value: p,
                  label: Text(p.displayName),
                ),
              if (automaticOffered)
                const ButtonSegment<MusicProvider?>(
                  value: null,
                  label: Text('Automatic'),
                ),
            ],
            selected: <MusicProvider?>{automatic ? null : provider},
            onSelectionChanged: signInBusy
                ? null
                : (selection) {
                    final choice = selection.single;
                    if (choice == null) {
                      controller.selectAutomaticRouting();
                    } else {
                      controller.selectMusicProvider(choice);
                    }
                  },
          ),
          const SizedBox(height: 8),
          Text(
            automatic
                ? 'Likes from your media-button pattern go to whichever '
                    'connected service is playing, and to $name when none is.'
                : 'Likes from your media-button pattern go to this service.',
          ),
          if (blockedReason != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              blockedReason,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 24),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Text('$name setup', style: Theme.of(context).textTheme.titleMedium),
          if (automatic) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              'Automatic can send a like to either service, so each keeps its '
              'own sign-in and credentials. Everything below is $name: the '
              'service picked before Automatic went on, and the one a like '
              'falls back to.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 12),
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
          if (!isYouTubeMusic) ...<Widget>[
            const SizedBox(height: 20),
            const _SpotifyCredentials(),
          ],
          const SizedBox(height: 20),
          Row(
            children: <Widget>[
              if (!isYouTubeMusic) ...<Widget>[
                FilledButton(
                  onPressed: hasSpotifyClientId
                      ? controller.connectMusicService
                      : null,
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
          if (!isYouTubeMusic && !hasSpotifyClientId) ...<Widget>[
            const SizedBox(height: 4),
            const Text('Connect turns on once the client ID is saved.'),
          ],
          // The other service's credentials are otherwise unreachable while
          // Automatic is on: picking a service is what this screen follows,
          // and Automatic is the absence of a pick.
          if (automatic) ...<Widget>[
            const SizedBox(height: 20),
            Text(
              'Setting up the other service means picking it, which turns '
              'Automatic off. Turn Automatic back on when you are done.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final other in others)
                  OutlinedButton(
                    onPressed: signInBusy
                        ? null
                        : () => controller.selectMusicProvider(other),
                    child: Text('Set up ${other.displayName}'),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: controller.refreshBatteryOptimizationStatus,
              child: const Text('Refresh status'),
            ),
          ),
          const SizedBox(height: 20),
          const _SharedLikeCounter(),
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
          'Optional. The thumbs-up works without it. Signing in only adds the '
          'Data API fallback and the shared like counter.',
        ),
        const SizedBox(height: 4),
        const Text(
          'Uses an OAuth client from your own Google Cloud project, of type '
          '"TVs and Limited Input devices", with YouTube Data API v3 enabled. '
          'Leave its consent screen in Testing with your account as a test '
          'user: publishing needs a privacy policy and terms on a domain you '
          'have verified. The price is that Google expires the sign-in after '
          '7 days, so you repeat it about once a week. The client secret is '
          'shown only when the client is created — if you lose it, add a new '
          'one under Google Auth Platform → Clients.',
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

  Future<void> _copyCode(String code) =>
      _copyToClipboard(context, code, 'Code copied');

  Future<void> _openUrl(String url) => _openExternalUrl(context, url);
}

/// Copies [text] and says so, the one way this screen confirms a copy.
Future<void> _copyToClipboard(
  BuildContext context,
  String text,
  String message,
) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}

/// Opens [url] in a browser, and falls back to telling the user the address
/// when there is no browser to open it with.
Future<void> _openExternalUrl(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  var opened = false;
  if (uri != null) {
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
  }
  if (opened || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Could not open a browser. Go to $url manually.')),
  );
}

/// The Spotify app's client ID, plus the redirect URI that has to be pasted
/// into the dashboard beside it.
class _SpotifyCredentials extends ConsumerStatefulWidget {
  const _SpotifyCredentials();

  @override
  ConsumerState<_SpotifyCredentials> createState() =>
      _SpotifyCredentialsState();
}

class _SpotifyCredentialsState extends ConsumerState<_SpotifyCredentials> {
  /// Where the app (and therefore the client ID) is created.
  static const _dashboardUrl = 'https://developer.spotify.com/dashboard';

  /// The README's Spotify section, so this card need not repeat the long form.
  static const _setupGuideUrl =
      'https://github.com/Osasuwu/like-current-song#1-spotify-developer-app';

  final _clientId = TextEditingController();
  bool _prefilled = false;

  @override
  void dispose() {
    _clientId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final credentials = ref.watch(serviceCredentialsControllerProvider);
    final controller = ref.read(serviceCredentialsControllerProvider.notifier);
    final theme = Theme.of(context);

    if (!_prefilled && credentials.loaded) {
      _prefilled = true;
      _clientId.text = credentials.spotifyClientId;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Spotify credentials', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text(
          'Uses an app from your own Spotify developer dashboard, so the likes '
          'are made by you and count against your own quota. Create an app '
          'with the Web API enabled and paste its client ID here. There is no '
          'client secret: this app signs in with PKCE.',
        ),
        Wrap(
          spacing: 8,
          children: <Widget>[
            TextButton.icon(
              onPressed: () => _openExternalUrl(context, _dashboardUrl),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Spotify dashboard'),
            ),
            TextButton.icon(
              onPressed: () => _openExternalUrl(context, _setupGuideUrl),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Setup steps'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text(
          'Add this redirect URI to the app in the dashboard, exactly as '
          'shown. Sign-in fails without it.',
        ),
        Row(
          children: <Widget>[
            Expanded(
              child: SelectableText(
                AppConstants.spotifyRedirectUri,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ),
            IconButton(
              tooltip: 'Copy redirect URI',
              icon: const Icon(Icons.copy),
              onPressed: () => _copyToClipboard(
                context,
                AppConstants.spotifyRedirectUri,
                'Redirect URI copied',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _clientId,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'Client ID',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => controller.saveSpotifyClientId(_clientId.text),
          child: const Text('Save client ID'),
        ),
        if (credentials.spotifySaved) ...<Widget>[
          const SizedBox(height: 4),
          const Text('Credentials saved.'),
        ],
        if (credentials.spotifyError != null) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            credentials.spotifyError!,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
      ],
    );
  }
}

/// The optional Google Sheet behind the cross-device like counter, and the
/// Google sign-in that writes to it. Collapsed by default: everything above
/// works without it.
class _SharedLikeCounter extends ConsumerStatefulWidget {
  const _SharedLikeCounter();

  @override
  ConsumerState<_SharedLikeCounter> createState() => _SharedLikeCounterState();
}

class _SharedLikeCounterState extends ConsumerState<_SharedLikeCounter> {
  /// The README's counter section: making the sheet and its header row.
  static const _setupGuideUrl =
      'https://github.com/Osasuwu/like-current-song#4-cross-device-counters-optional';

  final _clientId = TextEditingController();
  final _clientSecret = TextEditingController();
  final _spreadsheetId = TextEditingController();
  bool _prefilledCredentials = false;
  bool _prefilledSheet = false;
  bool _secretHidden = true;

  @override
  void dispose() {
    _clientId.dispose();
    _clientSecret.dispose();
    _spreadsheetId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final credentials = ref.watch(serviceCredentialsControllerProvider);
    final controller = ref.read(serviceCredentialsControllerProvider.notifier);
    final signIn = ref.watch(likeCounterSignInControllerProvider);
    final signInController =
        ref.read(likeCounterSignInControllerProvider.notifier);
    final theme = Theme.of(context);

    final saved = signIn.credentials;
    if (!_prefilledCredentials && saved != null) {
      _prefilledCredentials = true;
      _clientId.text = saved.clientId;
      _clientSecret.text = saved.clientSecret;
    }
    if (!_prefilledSheet && credentials.loaded) {
      _prefilledSheet = true;
      _spreadsheetId.text = credentials.counter.spreadsheetId;
    }

    // A created sheet has to land in the field too, or the box the user reads
    // as "the sheet in use" would still be empty next to a live counter.
    ref.listen<ServiceCredentialsState>(
      serviceCredentialsControllerProvider,
      (previous, next) {
        final id = next.counter.spreadsheetId;
        if (id == previous?.counter.spreadsheetId) return;
        if (_spreadsheetId.text != id) _spreadsheetId.text = id;
      },
    );

    final prompt = signIn.prompt;
    final created = credentials.createdCounter;
    return ExpansionTile(
      title: const Text('Shared like counter (optional)'),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'Counts how often you like the same track across your devices, in a '
          'Google Sheet of your own — the same sheet the desktop app writes to. '
          'Leave the spreadsheet ID blank and likes are counted on this device '
          'only.',
        ),
        const SizedBox(height: 4),
        const Text(
          'Sign in below and the app can make the sheet for you, or you can '
          'paste the ID of one you already have — a sheet another device is '
          'already counting in, say.',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => _openExternalUrl(context, _setupGuideUrl),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('Setup steps'),
          ),
        ),
        const SizedBox(height: 8),
        Text('Google sign-in', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        const Text(
          'The counter signs in to Google on its own, separately from the music '
          'service, so it keeps counting whichever service you pick. It needs '
          'an OAuth client of type "TVs and Limited Input devices" on a project '
          'with the Google Sheets API enabled — the same client you made for '
          'YouTube Music will do, once that API is enabled on its project.',
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
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            OutlinedButton(
              onPressed: signIn.busy
                  ? null
                  : () => signInController.saveCredentials(
                        clientId: _clientId.text,
                        clientSecret: _clientSecret.text,
                      ),
              child: const Text('Save credentials'),
            ),
            FilledButton(
              onPressed: signIn.busy || !signIn.hasCredentials
                  ? null
                  : signInController.connect,
              child: const Text('Sign in with Google'),
            ),
            if (credentials.counter.isSignedIn)
              TextButton(
                onPressed: signIn.busy ? null : _signOut,
                child: const Text('Sign out'),
              ),
          ],
        ),
        if (!signIn.hasCredentials) ...<Widget>[
          const SizedBox(height: 4),
          const Text(
            'Sign in turns on once the client ID and secret are saved.',
          ),
        ],
        if (signIn.credentialsSaved) ...<Widget>[
          const SizedBox(height: 4),
          const Text('Credentials saved.'),
        ],
        if (credentials.counter.isSignedIn &&
            signIn.phase == DeviceSignInPhase.idle) ...<Widget>[
          const SizedBox(height: 4),
          const Text('Signed in to Google.'),
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
                        onPressed: () => _copyToClipboard(
                          context,
                          prompt.userCode,
                          'Code copied',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton.tonal(
                        onPressed: () =>
                            _openExternalUrl(context, prompt.verificationUrl),
                        child: const Text('Open in browser'),
                      ),
                      TextButton(
                        onPressed: signInController.cancel,
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
        const SizedBox(height: 16),
        Text('Spreadsheet', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        const Text(
          'The app can make one for you, in your own Google Drive, with both '
          'tabs and their header rows already filled in. It uses the sign-in '
          'above and asks for no permission beyond the one you already gave.',
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: credentials.counterCreating ||
                    !credentials.counter.isSignedIn ||
                    credentials.hasCounterSpreadsheet
                ? null
                : controller.createCounterSpreadsheet,
            icon: credentials.counterCreating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.note_add_outlined, size: 18),
            label: Text(
              credentials.counterCreating
                  ? 'Creating...'
                  : 'Create a sheet for me',
            ),
          ),
        ),
        // Why the button is off, rather than leaving the user to guess. The
        // already-configured case comes first: it is the one where nothing
        // is wrong and nothing needs fixing.
        if (credentials.hasCounterSpreadsheet) ...<Widget>[
          const SizedBox(height: 4),
          const Text(
            'A spreadsheet is already set up, so this will not make a second '
            'one. Clear the ID below and save if you want a fresh sheet.',
          ),
        ] else if (!credentials.counter.isSignedIn) ...<Widget>[
          const SizedBox(height: 4),
          const Text('Sign in to Google above first.'),
        ],
        if (created != null) ...<Widget>[
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'Created "Like Current Song counters" in your Google '
                    'Drive. Point your other devices at this same ID to share '
                    'the count.',
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: SelectableText(
                          created.spreadsheetId,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(fontFamily: 'monospace'),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy spreadsheet ID',
                        icon: const Icon(Icons.copy),
                        onPressed: () => _copyToClipboard(
                          context,
                          created.spreadsheetId,
                          'Spreadsheet ID copied',
                        ),
                      ),
                    ],
                  ),
                  // Google usually returns the URL, but the id is what the
                  // counter needs; a missing URL is not worth an error.
                  if (created.url != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () =>
                            _openExternalUrl(context, created.url!),
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('Open the sheet'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        const Text(
          'Already have a sheet? Paste its ID — the long part of its address, '
          'between /d/ and /edit. It needs a tab named Likes whose first row '
          'is the header user_id, track_id, count, backfilled, updated_at.',
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _spreadsheetId,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'Spreadsheet ID',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: () =>
                controller.saveCounterSpreadsheetId(_spreadsheetId.text),
            child: const Text('Save counter settings'),
          ),
        ),
        if (credentials.counterSaved) ...<Widget>[
          const SizedBox(height: 4),
          const Text('Counter settings saved.'),
        ],
        if (credentials.counterError != null) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            credentials.counterError!,
            style: TextStyle(color: theme.colorScheme.error),
          ),
          // A failure that names a page to go and fix it gets a button to
          // that page: the URL Google hands back for a Cloud project whose
          // Sheets API is off is far too long to copy off a phone screen.
          if (credentials.counterErrorUrl != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _openExternalUrl(
                  context,
                  credentials.counterErrorUrl!,
                ),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Enable the Google Sheets API'),
              ),
            ),
        ],
      ],
    );
  }

  /// Drops the counter's Google tokens, then re-reads the config so the card
  /// stops claiming it is signed in.
  Future<void> _signOut() async {
    await ref.read(likeCounterAccountProvider).signOut();
    if (!mounted) return;
    await ref
        .read(serviceCredentialsControllerProvider.notifier)
        .refreshCounter();
  }
}
