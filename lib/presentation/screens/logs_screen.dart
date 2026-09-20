import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/app_log.dart';
import '../state/app_providers.dart';
import '../widgets/screen_padding.dart';

class LogsScreen extends ConsumerWidget {
  const LogsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logs = ref.watch(appControllerProvider.select((s) => s.logs));
    final controller = ref.read(appControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs / debug'),
        actions: <Widget>[
          IconButton(
            onPressed: controller.exportDiagnostics,
            tooltip: 'Export diagnostics',
            icon: const Icon(Icons.ios_share),
          ),
          IconButton(
            onPressed: controller.clearLogs,
            tooltip: 'Clear logs',
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: logs.isEmpty
          ? const Center(child: Text('No logs yet'))
          : ListView.separated(
              padding: scrollBodyPadding(context, base: EdgeInsets.zero),
              itemCount: logs.length,
              separatorBuilder: (_, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final log = logs[index];
                final subtitleParts = <String>[
                  log.actionType,
                  if (log.targetId != null) log.targetId!,
                  if (log.httpCode != null) 'HTTP ${log.httpCode}',
                ];
                return ListTile(
                  dense: true,
                  leading: Icon(
                    switch (log.result) {
                      LogResult.success => Icons.check_circle_outline,
                      LogResult.failure => Icons.error_outline,
                      LogResult.info => Icons.info_outline,
                    },
                    color: switch (log.result) {
                      LogResult.success => Colors.green,
                      LogResult.failure => Colors.red,
                      LogResult.info => Colors.grey,
                    },
                  ),
                  title: Text(log.message),
                  subtitle: Text(subtitleParts.join(' · ')),
                );
              },
            ),
    );
  }
}
