import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'presentation/screens/about_screen.dart';
import 'presentation/screens/battery_optimization_screen.dart';
import 'presentation/screens/connected_services_screen.dart';
import 'presentation/screens/logs_screen.dart';
import 'presentation/screens/main_screen.dart';
import 'presentation/screens/permissions_screen.dart';
import 'presentation/screens/trigger_config_screen.dart';

class LikeSpotifyApp extends ConsumerWidget {
  const LikeSpotifyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'Like Current Song',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      initialRoute: '/',
      routes: <String, WidgetBuilder>{
        '/': (_) => const MainScreen(),
        '/trigger-config': (_) => const TriggerConfigScreen(),
        '/connected-services': (_) => const ConnectedServicesScreen(),
        '/battery': (_) => const BatteryOptimizationScreen(),
        '/logs': (_) => const LogsScreen(),
        '/permissions': (_) => const PermissionsScreen(),
        '/about': (_) => const AboutScreen(),
      },
    );
  }
}
