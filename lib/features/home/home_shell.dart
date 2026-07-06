import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Bottom-navigation (or side-rail) shell shown once a watch is connected.
///
/// Follows the refreshed tab order: Summary, Health, History, Settings.
/// Notifications are now a subsection of Settings and no longer have a tab.
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
                    label: Text('Summary'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.favorite_outline),
                    selectedIcon: Icon(Icons.favorite),
                    label: Text('Health'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.show_chart_outlined),
                    selectedIcon: Icon(Icons.show_chart),
                    label: Text('History'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: Text('Settings'),
                  ),
                ],
              ),
            ),
            VerticalDivider(
              width: 1,
              color: theme.dividerColor.withValues(alpha: 0.6),
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
              color: theme.dividerColor.withValues(alpha: 0.6),
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
                label: 'Summary',
              ),
              NavigationDestination(
                icon: Icon(Icons.favorite_outline),
                selectedIcon: Icon(Icons.favorite),
                label: 'Health',
              ),
              NavigationDestination(
                icon: Icon(Icons.show_chart_outlined),
                selectedIcon: Icon(Icons.show_chart),
                label: 'History',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
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
