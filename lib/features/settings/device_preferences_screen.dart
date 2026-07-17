import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../../core/services/watch_manager.dart';
import '../../core/ui/ui_constants.dart';
import '../widgets/health_widgets.dart';

/// Watch-side preferences surfaced from `PROTOCOL.md` §4.2.
///
/// The watch persists its own copy of every value here — these calls are
/// idempotent and the user can re-apply any of them after a factory
/// reset.
class DevicePreferencesScreen extends ConsumerWidget {
  const DevicePreferencesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(watchManagerProvider);
    final ready = manager.isReady;
    final caps = manager.capabilities;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Watch preferences')),
      body: MaxWidthContainer(
        child: ListView(
          padding: const EdgeInsets.only(bottom: kScreenPaddingBottom),
          children: [
            if (!ready)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: kCardPadding,
                  vertical: kSpacingTiny,
                ),
                child: HealthCard(
                  icon: Icons.bluetooth_disabled,
                  metricColor: theme.colorScheme.error,
                  caption: 'Connect a watch to change device-side preferences',
                  trailing: StatusPill(
                    icon: Icons.info_outline,
                    label: 'Disconnected',
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            const HealthSectionHeader(title: 'Display'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
              child: InsetCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PreferenceTile(
                      icon: Icons.access_time_filled,
                      title: 'Time format',
                      subtitle: '12-hour vs 24-hour',
                      enabled: ready,
                      onTap: () => _pickTimeFormat(context, manager),
                    ),
                    _PreferenceTile(
                      icon: Icons.thermostat,
                      title: 'Temperature unit',
                      subtitle: 'Celsius / Fahrenheit',
                      enabled: ready,
                      onTap: () => _pickTemperatureUnit(context, manager),
                    ),
                    _PreferenceTile(
                      icon: Icons.auto_awesome,
                      title: 'Display clock',
                      subtitle: 'Always-on face when idle',
                      enabled: ready,
                      onTap: () => _toggleAutoMeasure(
                        context,
                        'Display clock',
                        manager.setDisplayClock,
                      ),
                    ),
                    _PreferenceTile(
                      icon: Icons.palette,
                      title: 'Theme',
                      subtitle: 'Pick a vendor theme id (0..N)',
                      enabled: ready,
                      onTap: () =>
                          _pickId(context, 'Theme id', manager.setTheme),
                    ),
                    _PreferenceTile(
                      icon: Icons.wallpaper,
                      title: 'Wallpaper',
                      subtitle: 'Pick a vendor wallpaper id (0..N)',
                      enabled: ready,
                      onTap: () => _pickId(
                        context,
                        'Wallpaper id',
                        manager.setWallpaper,
                      ),
                      showDivider: false,
                    ),
                  ],
                ),
              ),
            ),
            if (caps.bloodPressure || caps.stress || caps.bloodOxygen)
              const HealthSectionHeader(title: 'Auto-measure'),
            if (caps.bloodPressure || caps.stress || caps.bloodOxygen)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
                child: InsetCard(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (caps.bloodOxygen)
                        _PreferenceTile(
                          icon: CupertinoIcons.drop_fill,
                          title: 'Blood-oxygen auto-measure',
                          subtitle: 'Periodic SpO2 sampling',
                          enabled: ready,
                          onTap: () => _toggleAutoMeasure(
                            context,
                            'Blood-oxygen auto-measure',
                            manager.setBloodOxygenSetting,
                          ),
                        ),
                      if (caps.stress)
                        _PreferenceTile(
                          icon: CupertinoIcons.bolt_fill,
                          title: 'Stress auto-measure',
                          subtitle: 'Periodic pressure (stress) sampling',
                          enabled: ready,
                          onTap: () => _toggleAutoMeasure(
                            context,
                            'Stress auto-measure',
                            manager.setPressureSetting,
                          ),
                        ),
                      if (caps.bloodPressure)
                        _PreferenceTile(
                          icon: CupertinoIcons.waveform_path_ecg,
                          title: 'Blood-pressure window',
                          subtitle: 'Schedule BP measurement window',
                          enabled: ready,
                          onTap: () => _pickBpWindow(context, manager),
                          showDivider: false,
                        ),
                    ],
                  ),
                ),
              ),
            const HealthSectionHeader(title: 'Reminders'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
              child: InsetCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PreferenceTile(
                      icon: Icons.do_not_disturb_on,
                      title: 'Do not disturb',
                      subtitle: 'Configure a daily quiet window',
                      enabled: ready,
                      onTap: () => _pickDndWindow(context, manager),
                    ),
                    _PreferenceTile(
                      icon: Icons.airline_seat_recline_normal,
                      title: 'Sit reminder',
                      subtitle: 'Sedentary alert cadence',
                      enabled: ready,
                      onTap: () => _pickSitReminder(context, manager),
                    ),
                    _PreferenceTile(
                      icon: Icons.local_drink,
                      title: 'Drink alarm',
                      subtitle: 'Stay-hydrated reminder',
                      enabled: ready,
                      onTap: () => _pickDrinkAlarm(context, manager),
                      showDivider: false,
                    ),
                  ],
                ),
              ),
            ),
            const HealthSectionHeader(title: 'Goals'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
              child: InsetCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PreferenceTile(
                      icon: Icons.flag,
                      title: 'Daily goals',
                      subtitle: 'Steps / calories / distance targets',
                      enabled: ready,
                      onTap: () => _pickTarget(context, manager),
                      showDivider: false,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickTimeFormat(
    BuildContext context,
    WatchManager manager,
  ) async {
    final pick = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HealthListTile(
              title: '24-hour',
              leadingIcon: Icons.access_time,
              leadingColor: Theme.of(context).colorScheme.onSurfaceVariant,
              showDivider: false,
              onTap: () => Navigator.pop(ctx, true),
            ),
            HealthListTile(
              title: '12-hour',
              leadingIcon: Icons.access_time_filled,
              leadingColor: Theme.of(context).colorScheme.onSurfaceVariant,
              showDivider: false,
              onTap: () => Navigator.pop(ctx, false),
            ),
          ],
        ),
      ),
    );
    if (pick == null || !context.mounted) return;
    await _apply(
      context,
      () => manager.setTimeFormat(is24: pick, metric: pick),
      'Time format updated',
    );
  }

  Future<void> _pickTemperatureUnit(
    BuildContext context,
    WatchManager manager,
  ) async {
    final pick = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HealthListTile(
              title: 'Celsius',
              leadingIcon: Icons.thermostat,
              leadingColor: Theme.of(context).colorScheme.onSurfaceVariant,
              showDivider: false,
              onTap: () => Navigator.pop(ctx, true),
            ),
            HealthListTile(
              title: 'Fahrenheit',
              leadingIcon: Icons.thermostat,
              leadingColor: Theme.of(context).colorScheme.onSurfaceVariant,
              showDivider: false,
              onTap: () => Navigator.pop(ctx, false),
            ),
          ],
        ),
      ),
    );
    if (pick == null || !context.mounted) return;
    await _apply(
      context,
      () => manager.setDegreeSwitch(enabled: true, isCelsius: pick),
      'Temperature unit updated',
    );
  }

  Future<void> _pickId(
    BuildContext context,
    String title,
    Future<void> Function(int) onPick,
  ) async {
    final ctl = TextEditingController(text: '0');
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: AppTextStyles.titleLarge(context)),
        content: TextField(
          controller: ctl,
          keyboardType: TextInputType.number,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final v = int.tryParse(ctl.text);
              Navigator.pop(ctx, v);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (picked == null || !context.mounted) return;
    await _apply(context, () => onPick(picked.clamp(0, 255)), 'Sent');
  }

  Future<void> _toggleAutoMeasure(
    BuildContext context,
    String title,
    Future<void> Function({required bool enabled}) onPick,
  ) async {
    final pick = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HealthListTile(
              title: 'Enable',
              leadingIcon: Icons.toggle_on,
              leadingColor: Theme.of(context).colorScheme.onSurfaceVariant,
              showDivider: false,
              onTap: () => Navigator.pop(ctx, true),
            ),
            HealthListTile(
              title: 'Disable',
              leadingIcon: Icons.toggle_off,
              leadingColor: Theme.of(context).colorScheme.onSurfaceVariant,
              showDivider: false,
              onTap: () => Navigator.pop(ctx, false),
            ),
          ],
        ),
      ),
    );
    if (pick == null || !context.mounted) return;
    await _apply(
      context,
      () => onPick(enabled: pick),
      '$title ${pick ? 'enabled' : 'disabled'}',
    );
  }

  Future<void> _pickDndWindow(
    BuildContext context,
    WatchManager manager,
  ) async {
    final start = await _pickTimeOfDay(
      context,
      'Start time',
      initial: const TimeOfDay(hour: 22, minute: 0),
    );
    if (start == null) return;
    if (!context.mounted) return;
    final end = await _pickTimeOfDay(
      context,
      'End time',
      initial: const TimeOfDay(hour: 7, minute: 0),
    );
    if (end == null) return;
    if (!context.mounted) return;
    await _apply(
      context,
      () => manager.setDnd(
        enabled: true,
        startHour: start.hour,
        startMinute: start.minute,
        endHour: end.hour,
        endMinute: end.minute,
      ),
      'Do-not-disturb set',
    );
  }

  Future<void> _pickSitReminder(
    BuildContext context,
    WatchManager manager,
  ) async {
    final start = await _pickTimeOfDay(
      context,
      'Start time',
      initial: const TimeOfDay(hour: 9, minute: 0),
    );
    if (start == null) return;
    if (!context.mounted) return;
    final end = await _pickTimeOfDay(
      context,
      'End time',
      initial: const TimeOfDay(hour: 18, minute: 0),
    );
    if (end == null) return;
    if (!context.mounted) return;
    final cycle = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final c in [30, 60, 90])
              HealthListTile(
                title: 'Every $c minutes',
                leadingIcon: Icons.timer,
                leadingColor: Theme.of(context).colorScheme.onSurfaceVariant,
                showDivider: false,
                onTap: () => Navigator.pop(ctx, c),
              ),
          ],
        ),
      ),
    );
    if (cycle == null || !context.mounted) {
      return;
    }
    await _apply(
      context,
      () => manager.setSitLong(
        enabled: true,
        startHour: start.hour,
        startMinute: start.minute,
        endHour: end.hour,
        endMinute: end.minute,
        weekMask: 0x1F, // weekdays only — sensible default
        cycleSeconds:
            cycle ~/ 2, // 30/60/90 → 15/30/45 (firmware clamps to 30/60/90)
      ),
      'Sit reminder set',
    );
  }

  Future<void> _pickDrinkAlarm(
    BuildContext context,
    WatchManager manager,
  ) async {
    final hour = await _pickTimeOfDay(
      context,
      'Drink alarm time',
      initial: const TimeOfDay(hour: 14, minute: 0),
    );
    if (hour == null || !context.mounted) return;
    await _apply(
      context,
      () => manager.setDrinkAlarm(
        index: 0,
        enabled: true,
        hour: hour.hour,
        minute: hour.minute,
        weekdays: const [true, true, true, true, true, true, true],
      ),
      'Drink alarm set',
    );
  }

  Future<void> _pickBpWindow(BuildContext context, WatchManager manager) async {
    final start = await _pickTimeOfDay(
      context,
      'Start time',
      initial: const TimeOfDay(hour: 8, minute: 0),
    );
    if (start == null) return;
    if (!context.mounted) return;
    final end = await _pickTimeOfDay(
      context,
      'End time',
      initial: const TimeOfDay(hour: 20, minute: 0),
    );
    if (end == null || !context.mounted) return;
    await _apply(
      context,
      () => manager.setBpSetting(
        enabled: true,
        startHour: start.hour,
        startMinute: start.minute,
        endHour: end.hour,
        endMinute: end.minute,
      ),
      'BP window set',
    );
  }

  Future<void> _pickTarget(BuildContext context, WatchManager manager) async {
    final stepsCtl = TextEditingController(text: '8000');
    final calCtl = TextEditingController(text: '2000');
    final distCtl = TextEditingController(text: '5000');
    final picked = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Daily goals', style: AppTextStyles.titleLarge(context)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: stepsCtl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Steps'),
            ),
            TextField(
              controller: calCtl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Calories'),
            ),
            TextField(
              controller: distCtl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Distance (m)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (picked != true) {
      stepsCtl.dispose();
      calCtl.dispose();
      distCtl.dispose();
      return;
    }
    final steps = int.tryParse(stepsCtl.text) ?? 0;
    final cal = int.tryParse(calCtl.text) ?? 0;
    final dist = int.tryParse(distCtl.text) ?? 0;
    stepsCtl.dispose();
    calCtl.dispose();
    distCtl.dispose();
    if (!context.mounted) return;
    await _apply(
      context,
      () =>
          manager.setTarget(steps: steps, calories: cal, distanceMeters: dist),
      'Goals updated',
    );
  }

  Future<TimeOfDay?> _pickTimeOfDay(
    BuildContext context,
    String title, {
    required TimeOfDay initial,
  }) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: title,
    );
    return picked;
  }

  /// Runs a watch-side mutation and reports the outcome. A BLE write can
  /// fail (dropped link mid-write); without this the failure surfaced as an
  /// unhandled async error and the user was left believing the change
  /// applied.
  Future<void> _apply(
    BuildContext context,
    Future<void> Function() action,
    String success,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      messenger.showSnackBar(SnackBar(content: Text(success)));
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not apply — check the watch connection'),
        ),
      );
    }
  }
}

class _PreferenceTile extends StatelessWidget {
  const _PreferenceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
    this.showDivider = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return HealthListTile(
      title: title,
      subtitle: subtitle,
      leadingIcon: icon,
      leadingColor: theme.colorScheme.onSurfaceVariant,
      trailing: ChevronIcon(
        color: enabled
            ? theme.colorScheme.onSurfaceVariant
            : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.38),
      ),
      onTap: enabled ? onTap : null,
      showDivider: showDivider,
    );
  }
}
