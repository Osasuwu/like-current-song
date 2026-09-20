import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_providers.dart';

class BatteryOptimizationScreen extends ConsumerWidget {
  const BatteryOptimizationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appControllerProvider);
    final controller = ref.read(appControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Battery optimization status')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                state.batteryOptimized
                    ? 'Battery optimization is ENABLED (recommended to disable for reliability).'
                    : 'Battery optimization is DISABLED for this app.',
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: controller.requestBatteryOptimizationExemption,
                child: const Text('Request exemption'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: controller.openBatteryOptimizationSettings,
                child: const Text('Open battery settings'),
              ),
              const SizedBox(height: 24),
              Text('MIUI device detected: ${state.isMiui ? 'Yes' : 'No'}'),
              if (state.isMiui) ...<Widget>[
                const SizedBox(height: 8),
                const Text(
                  'MIUI steps:\n'
                  '1) Enable Auto-start for this app\n'
                  '2) Set Battery saver to No restrictions',
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: controller.openMiuiAutostartSettings,
                  child: const Text('Open MIUI autostart settings'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
