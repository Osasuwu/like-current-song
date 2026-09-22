import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/app_log.dart';
import '../state/app_providers.dart';
import '../widgets/screen_padding.dart';

const List<String> _monthNames = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// `18:34` for an event from today, `22 Sep 18:34` for an older one and
/// `22 Sep 2025 18:34` once the year differs too.
///
/// Entries recorded while the app was closed can be days old by the time
/// anyone reads them (see `BackgroundLog` on the native side), so a bare clock
/// time would quietly pass a line from last week off as something that just
/// happened. [now] exists so tests do not depend on the day they run on.
@visibleForTesting
String formatLogTime(DateTime at, {DateTime? now}) {
  String two(int value) => value.toString().padLeft(2, '0');

  // Stored in UTC; read on a wall clock.
  final local = at.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final clock = '${two(local.hour)}:${two(local.minute)}';

  if (local.year == today.year &&
      local.month == today.month &&
      local.day == today.day) {
    return clock;
  }
  final date = '${local.day} ${_monthNames[local.month - 1]}';
  if (local.year == today.year) {
    return '$date $clock';
  }
  return '$date ${local.year} $clock';
}

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
                  // First: with the list in reverse order, when something
                  // happened is what the eye scans down the column for.
                  formatLogTime(log.at),
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
