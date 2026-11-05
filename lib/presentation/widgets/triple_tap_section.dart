import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/entities/triple_tap_status.dart';

/// The command that grants the hidden media-key listener permission (#158).
/// Android lets only the shell grant it, so it cannot be asked for in-app.
const tripleTapGrantCommand =
    'adb shell pm grant com.osasuwu.like_spotify '
    'android.permission.SET_MEDIA_KEY_LISTENER';

/// The opt-in "like on the earbuds' triple tap" block of the trigger settings.
///
/// The switch is saved with the rest of the trigger; [status] is what the
/// native listener last said stands in the way (null while it is being
/// read), and [onRecheck] reads it again — the grant and the earbuds change
/// outside the app, so the screen cannot know when to look by itself.
///
/// Stateless: the owning screen keeps the switch value and the status.
class TripleTapSection extends StatelessWidget {
  const TripleTapSection({
    super.key,
    required this.enabled,
    required this.onEnabledChanged,
    required this.status,
    required this.onRecheck,
  });

  final bool enabled;
  final ValueChanged<bool> onEnabledChanged;
  final TripleTapStatus? status;
  final VoidCallback onRecheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text("Like on the earbuds' triple tap"),
          subtitle: const Text(
            'While music plays, the earbuds\' "previous" likes the track '
            'instead of skipping back.',
          ),
          value: enabled,
          onChanged: onEnabledChanged,
        ),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                status?.label ?? 'Checking…',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            TextButton(onPressed: onRecheck, child: const Text('Check again')),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'One-time setup: connect the phone to a computer with USB '
          'debugging on, and run',
          style: hint,
        ),
        Row(
          children: <Widget>[
            const Expanded(
              child: SelectableText(
                tripleTapGrantCommand,
                style: TextStyle(fontFamily: 'monospace'),
              ),
            ),
            IconButton(
              tooltip: 'Copy command',
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(
                  const ClipboardData(text: tripleTapGrantCommand),
                );
                if (!context.mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Command copied')));
              },
            ),
          ],
        ),
        Text(
          'No computer? Any Shizuku-based shell app on the phone can run the '
          'same command.',
          style: hint,
        ),
        const SizedBox(height: 4),
        Text(
          'It works only if your earbuds send "previous" on a triple tap; '
          'most do, but some give that gesture to the voice assistant.',
          style: hint,
        ),
        const SizedBox(height: 4),
        Text(
          'While this is on, a "previous" from any Bluetooth device — a car, '
          'a speaker — likes the playing track instead of skipping back.',
          style: hint,
        ),
      ],
    );
  }
}
