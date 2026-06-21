import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/dashboard/dashboard_screen.dart';
import '../../features/firmware/firmware_screen.dart';
import '../../features/health/health_screen.dart';
import '../../features/history/history_screen.dart';
import '../../features/home/home_shell.dart';
import '../../features/logs/logs_screen.dart';
import '../../features/notifications/notifications_screen.dart';
import '../../features/scan/scan_screen.dart';
import '../../features/settings/sensor_settings_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../services/opentelemetry_service.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

final appRouterProvider = Provider<GoRouter>(
  (ref) => GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/scan',
    observers: [
      // Attach the OTel route observer at the GoRouter level so the
      // navigator it owns emits route-change spans. MaterialApp.router's
      // own navigatorObservers only sees the outer Navigator, which
      // misses the go_router-driven pushes.
      OpenTelemetryService().routeObserver,
    ],
    routes: [
      GoRoute(
        path: '/scan',
        name: 'scan',
        builder: (context, state) => const ScanScreen(),
      ),
      GoRoute(
        path: '/firmware',
        name: 'firmware',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const FirmwareScreen(),
      ),
      GoRoute(
        path: '/logs',
        name: 'logs',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const LogsScreen(),
      ),
      GoRoute(
        path: '/history',
        name: 'history',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const HistoryScreen(),
      ),
      GoRoute(
        path: '/sensor-settings',
        name: 'sensor-settings',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (context, state) => const SensorSettingsScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/dashboard',
                name: 'dashboard',
                builder: (context, state) => const DashboardScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/health',
                name: 'health',
                builder: (context, state) => const HealthScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/notifications',
                name: 'notifications',
                builder: (context, state) => const NotificationsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                name: 'settings',
                builder: (context, state) => const SettingsScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  ),
);
