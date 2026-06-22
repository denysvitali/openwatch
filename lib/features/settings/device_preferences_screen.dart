import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ble/ble_transport.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/watch_manager.dart';

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
    final ready = (ref.watch(linkStateProvider).value) == LinkState.ready;
    final caps = manager.capabilities;

    return Scaffold(
      appBar: AppBar(title: const Text('Watch preferences')),
      body: ListView(
        children: [
          const _SectionHeader('Display'),
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
            onTap: () => _toggleDisplayClock(context, manager),
          ),
          _PreferenceTile(
            icon: Icons.palette,
            title: 'Theme',
            subtitle: 'Pick a vendor theme id (0..N)',
            enabled: ready,
            onTap: () => _pickId(context, 'Theme id', manager.setTheme),
          ),
          _PreferenceTile(
            icon: Icons.wallpaper,
            title: 'Wallpaper',
            subtitle: 'Pick a vendor wallpaper id (0..N)',
            enabled: ready,
            onTap: () => _pickId(context, 'Wallpaper id', manager.setWallpaper),
          ),
          if (caps.bloodPressure || caps.hrv || caps.stress || caps.bloodOxygen)
            const _SectionHeader('Auto-measure'),
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
          if (caps.hrv)
            _PreferenceTile(
              icon: CupertinoIcons.chart_bar_fill,
              title: 'HRV auto-measure',
              subtitle: 'Periodic HRV sampling',
              enabled: ready,
              onTap: () => _toggleHrvSetting(context, manager),
            ),
          if (caps.bloodPressure)
            _PreferenceTile(
              icon: CupertinoIcons.waveform_path_ecg,
              title: 'Blood-pressure window',
              subtitle: 'Schedule BP measurement window',
              enabled: ready,
              onTap: () => _pickBpWindow(context, manager),
            ),
          const _SectionHeader('Reminders'),
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
          ),
          const _SectionHeader('Goals'),
          _PreferenceTile(
            icon: Icons.flag,
            title: 'Daily goals',
            subtitle: 'Steps / calories / distance targets',
            enabled: ready,
            onTap: () => _pickTarget(context, manager),
          ),
        ],
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
            ListTile(
              leading: const Icon(Icons.access_time),
              title: const Text('24-hour'),
              onTap: () => Navigator.pop(ctx, true),
            ),
            ListTile(
              leading: const Icon(Icons.access_time_filled),
              title: const Text('12-hour'),
              onTap: () => Navigator.pop(ctx, false),
            ),
          ],
        ),
      ),
    );
    if (pick == null) return;
    await manager.setTimeFormat(is24: pick, metric: pick);
    if (context.mounted) _toast(context, 'Time format updated');
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
            ListTile(
              leading: const Icon(Icons.thermostat),
              title: const Text('Celsius'),
              onTap: () => Navigator.pop(ctx, true),
            ),
            ListTile(
              leading: const Icon(Icons.thermostat),
              title: const Text('Fahrenheit'),
              onTap: () => Navigator.pop(ctx, false),
            ),
          ],
        ),
      ),
    );
    if (pick == null) return;
    await manager.setDegreeSwitch(enabled: true, isCelsius: pick);
    if (context.mounted) _toast(context, 'Temperature unit updated');
  }

  Future<void> _toggleDisplayClock(
    BuildContext context,
    WatchManager manager,
  ) async {
    final pick = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.toggle_on),
              title: const Text('Enable'),
              onTap: () => Navigator.pop(ctx, true),
            ),
            ListTile(
              leading: const Icon(Icons.toggle_off),
              title: const Text('Disable'),
              onTap: () => Navigator.pop(ctx, false),
            ),
          ],
        ),
      ),
    );
    if (pick == null) return;
    await manager.setDisplayClock(enabled: pick);
    if (context.mounted) _toast(context, 'Display clock updated');
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
        title: Text(title),
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
    if (picked == null) return;
    await onPick(picked.clamp(0, 255));
    if (context.mounted) _toast(context, 'Sent');
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
            ListTile(
              leading: const Icon(Icons.toggle_on),
              title: const Text('Enable'),
              onTap: () => Navigator.pop(ctx, true),
            ),
            ListTile(
              leading: const Icon(Icons.toggle_off),
              title: const Text('Disable'),
              onTap: () => Navigator.pop(ctx, false),
            ),
          ],
        ),
      ),
    );
    if (pick == null) return;
    await onPick(enabled: pick);
    if (context.mounted) {
      _toast(context, '$title ${pick ? 'enabled' : 'disabled'}');
    }
  }

  Future<void> _toggleHrvSetting(
    BuildContext context,
    WatchManager manager,
  ) async {
    final pick = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.toggle_on),
              title: const Text('Enable'),
              onTap: () => Navigator.pop(ctx, true),
            ),
            ListTile(
              leading: const Icon(Icons.toggle_off),
              title: const Text('Disable'),
              onTap: () => Navigator.pop(ctx, false),
            ),
          ],
        ),
      ),
    );
    if (pick == null) return;
    await manager.setHrvSetting(enabled: pick);
    if (context.mounted) _toast(context, 'HRV auto-measure updated');
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
    await manager.setDnd(
      enabled: true,
      startHour: start.hour,
      startMinute: start.minute,
      endHour: end.hour,
      endMinute: end.minute,
    );
    if (context.mounted) _toast(context, 'Do-not-disturb set');
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
              ListTile(
                leading: const Icon(Icons.timer),
                title: Text('Every $c minutes'),
                onTap: () => Navigator.pop(ctx, c),
              ),
          ],
        ),
      ),
    );
    if (cycle == null) {
      return;
    }
    await manager.setSitLong(
      enabled: true,
      startHour: start.hour,
      startMinute: start.minute,
      endHour: end.hour,
      endMinute: end.minute,
      weekMask: 0x1F, // weekdays only — sensible default
      cycleSeconds:
          cycle ~/ 2, // 30/60/90 → 15/30/45 (firmware clamps to 30/60/90)
    );
    if (context.mounted) _toast(context, 'Sit reminder set');
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
    if (hour == null) return;
    await manager.setDrinkAlarm(
      index: 0,
      enabled: true,
      hour: hour.hour,
      minute: hour.minute,
      weekdays: const [true, true, true, true, true, true, true],
    );
    if (context.mounted) _toast(context, 'Drink alarm set');
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
    if (end == null) return;
    await manager.setBpSetting(
      enabled: true,
      startHour: start.hour,
      startMinute: start.minute,
      endHour: end.hour,
      endMinute: end.minute,
    );
    if (context.mounted) _toast(context, 'BP window set');
  }

  Future<void> _pickTarget(BuildContext context, WatchManager manager) async {
    final stepsCtl = TextEditingController(text: '8000');
    final calCtl = TextEditingController(text: '2000');
    final distCtl = TextEditingController(text: '5000');
    final picked = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Daily goals'),
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
    await manager.setTarget(steps: steps, calories: cal, distanceMeters: dist);
    if (context.mounted) _toast(context, 'Goals updated');
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

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

class _PreferenceTile extends StatelessWidget {
  const _PreferenceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      enabled: enabled,
      trailing: const Icon(Icons.chevron_right),
      onTap: enabled ? onTap : null,
    );
  }
}
