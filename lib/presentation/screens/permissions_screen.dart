import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_providers.dart';

class PermissionsScreen extends ConsumerWidget {
  const PermissionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Permissions')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('Required permissions and integration points:'),
              const SizedBox(height: 12),
              const Text('• Foreground service (media playback type)'),
              const Text('• Notification permission (Android 13+)'),
              Text(
                '• Notification access (playback fallback): ${state.notificationListenerEnabled ? 'Enabled' : 'Disabled'}',
              ),
              const Text('• Ignore battery optimization (recommended)'),
              Text('• Internet access for ${state.musicProvider.displayName}'),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: controller.ensureRuntimePermissions,
                child: const Text('Request notification permission (Android 13+)'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: controller.openNotificationSettings,
                child: const Text('Open notification settings'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: controller.openNotificationListenerSettings,
                child: const Text('Open notification access (required for fallback)'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: controller.refreshNotificationListenerStatus,
                child: const Text('Refresh notification access status'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: controller.requestBatteryOptimizationExemption,
                child: const Text('Request battery optimization exemption'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
