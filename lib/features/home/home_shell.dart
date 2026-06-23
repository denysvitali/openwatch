import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Bottom-navigation shell shown once a watch is connected.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 720;

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            SafeArea(
              right: false,
              child: NavigationRail(
                selectedIndex: navigationShell.currentIndex,
                onDestinationSelected: _goBranch,
                labelType: NavigationRailLabelType.all,
                minWidth: 86,
                groupAlignment: -0.82,
                leading: Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 18),
                  child: Icon(
                    Icons.watch_rounded,
                    color: theme.colorScheme.primary,
                    size: 30,
                  ),
                ),
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.watch_outlined),
                    selectedIcon: Icon(Icons.watch_rounded),
                    label: Text('Device'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(CupertinoIcons.heart),
                    selectedIcon: Icon(CupertinoIcons.heart_fill),
                    label: Text('Health'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(CupertinoIcons.bell),
                    selectedIcon: Icon(CupertinoIcons.bell_fill),
                    label: Text('Alerts'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(CupertinoIcons.gear_alt),
                    selectedIcon: Icon(CupertinoIcons.gear_alt_fill),
                    label: Text('Settings'),
                  ),
                ],
              ),
            ),
            VerticalDivider(
              width: 1,
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
            ),
            Expanded(child: navigationShell),
          ],
        ),
      );
    }

    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.94),
          border: Border(
            top: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
              width: 0.6,
            ),
          ),
        ),
        child: SafeArea(
          top: false,
          child: NavigationBar(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: _goBranch,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.watch_outlined),
                selectedIcon: Icon(Icons.watch_rounded),
                label: 'Device',
              ),
              NavigationDestination(
                icon: Icon(CupertinoIcons.heart),
                selectedIcon: Icon(CupertinoIcons.heart_fill),
                label: 'Health',
              ),
              NavigationDestination(
                icon: Icon(CupertinoIcons.bell),
                selectedIcon: Icon(CupertinoIcons.bell_fill),
                label: 'Alerts',
              ),
              NavigationDestination(
                icon: Icon(CupertinoIcons.gear_alt),
                selectedIcon: Icon(CupertinoIcons.gear_alt_fill),
                label: 'Settings',
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _goBranch(int i) {
    navigationShell.goBranch(
      i,
      initialLocation: i == navigationShell.currentIndex,
    );
  }
}
