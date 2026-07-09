import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:openwatch/core/ui/ui_constants.dart';

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
                minWidth: 92,
                groupAlignment: -0.82,
                leading: Padding(
                  padding: const EdgeInsets.only(
                    top: kSpacingMedium,
                    bottom: kSpacingSmall * 2 + kSpacingMini,
                  ),
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      Icons.watch_rounded,
                      color: theme.colorScheme.primary,
                      size: kIconSizeLarge,
                    ),
                  ),
                ),
                destinations: [
                  NavigationRailDestination(
                    icon: const Icon(Icons.watch_outlined),
                    selectedIcon: const Icon(Icons.watch_rounded),
                    label: Text(
                      'Summary',
                      style: AppTextStyles.labelSmall(context),
                    ),
                  ),
                  NavigationRailDestination(
                    icon: const Icon(Icons.favorite_outline),
                    selectedIcon: const Icon(Icons.favorite),
                    label: Text(
                      'Health',
                      style: AppTextStyles.labelSmall(context),
                    ),
                  ),
                  NavigationRailDestination(
                    icon: const Icon(Icons.show_chart_outlined),
                    selectedIcon: const Icon(Icons.show_chart),
                    label: Text(
                      'History',
                      style: AppTextStyles.labelSmall(context),
                    ),
                  ),
                  NavigationRailDestination(
                    icon: const Icon(Icons.settings_outlined),
                    selectedIcon: const Icon(Icons.settings),
                    label: Text(
                      'Settings',
                      style: AppTextStyles.labelSmall(context),
                    ),
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
          color: theme.colorScheme.surface.withValues(alpha: 0.97),
          border: Border(
            top: BorderSide(
              color: theme.dividerColor.withValues(alpha: 0.6),
              width: 0.6,
            ),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: kSpacingSmall),
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
