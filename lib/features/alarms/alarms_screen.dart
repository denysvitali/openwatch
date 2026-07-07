import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:openwatch/core/ui/ui_constants.dart';

import '../../core/protocol/channel_a.dart';
import '../../core/providers/app_providers.dart';
import '../../core/services/watch_manager.dart';
import '../widgets/health_widgets.dart';
import '../widgets/inset_card.dart';
import '../widgets/max_width_container.dart';

/// Clock-alarm management screen.
///
/// Lists the up-to-five slots the watch exposes (PROTOCOL.md §4.3),
/// lets the user tap an empty slot to add a new alarm, tap an existing
/// one to edit its time + weekdays, and long-press / tap-delete to
/// clear a slot.
///
/// The screen wires every action through `WatchManager` which owns the
/// slot cache — the UI is a pure reflection of `manager.alarms` and
/// survives reconnects without having to re-query on every rebuild.
class AlarmsScreen extends ConsumerWidget {
  const AlarmsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(watchManagerProvider);
    final ready = manager.isReady;
    final alarms = manager.alarms;
    final armedCount = alarms.where((alarm) => alarm.enabled).length;
    final supported = manager.capabilities.alarm;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Alarms'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh from watch',
            onPressed: ready ? () => manager.refreshAlarms() : null,
          ),
        ],
      ),
      body: MaxWidthContainer(
        child: !ready
            ? const _NotReady()
            : !supported
            ? const _Unsupported()
            : RefreshIndicator(
                onRefresh: manager.refreshAlarms,
                child: ListView(
                  padding: const EdgeInsets.only(
                    bottom: kSectionHeaderPaddingTop,
                  ),
                  children: [
                    const HealthSectionHeader(title: 'Clock alarms'),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: kCardPadding,
                      ),
                      child: _AlarmList(
                        alarms: alarms,
                        onEdit: (slot, alarm) =>
                            _showEditor(context, ref, slot: slot, alarm: alarm),
                        onDelete: (alarm) =>
                            _confirmDelete(context, ref, alarm),
                      ),
                    ),
                    const SizedBox(height: kGridSpacing),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: kCardPadding,
                      ),
                      child: Text(
                        armedCount == 0
                            ? 'No alarms yet. Tap an empty slot above to add one.'
                            : '$armedCount of ${WatchManager.alarmSlotCount} alarms armed.',
                        style: AppTextStyles.bodySmall(context),
                      ),
                    ),
                  ],
                ),
              ),
      ),
      floatingActionButton: (ready && supported)
          ? Padding(
              padding: const EdgeInsets.only(bottom: kGridSpacing),
              child: PrimaryHealthButton(
                icon: Icons.add_alarm,
                label: 'Add alarm',
                onPressed: () {
                  final slot = _nextFreeSlot(alarms);
                  if (slot == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('All slots full')),
                    );
                    return;
                  }
                  _showEditor(context, ref, slot: slot);
                },
              ),
            )
          : null,
    );
  }

  static int? _nextFreeSlot(List<Alarm> alarms) {
    final used = {
      for (final a in alarms)
        if (a.enabled) a.slot,
    };
    for (var i = 0; i < WatchManager.alarmSlotCount; i++) {
      if (!used.contains(i)) return i;
    }
    return null;
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Alarm alarm,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Clear alarm at ${alarm.labelTime}?'),
        content: const Text(
          'The slot is disabled and can be re-armed any time without '
          're-entering the time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(watchManagerProvider).deleteAlarm(slot: alarm.slot);
  }

  Future<void> _showEditor(
    BuildContext context,
    WidgetRef ref, {
    Alarm? alarm,
    required int slot,
  }) async {
    final manager = ref.read(watchManagerProvider);
    final initial =
        alarm ??
        Alarm(
          slot: slot,
          enabled: true,
          hour: 7,
          minute: 0,
          weekdays: const [false, false, false, false, false, false, false],
        );
    final edited = await showModalBottomSheet<Alarm>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _AlarmEditor(initial: initial),
    );
    if (edited == null) return;
    await manager.setAlarm(edited);
  }
}

class _AlarmList extends StatelessWidget {
  const _AlarmList({
    required this.alarms,
    required this.onEdit,
    required this.onDelete,
  });

  final List<Alarm> alarms;
  final void Function(int slot, Alarm? alarm) onEdit;
  final void Function(Alarm alarm) onDelete;

  @override
  Widget build(BuildContext context) {
    final bySlot = {for (final alarm in alarms) alarm.slot: alarm};
    return InsetCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < WatchManager.alarmSlotCount; i++)
            _AlarmRow(
              slot: i,
              alarm: bySlot[i],
              onEdit: () => onEdit(i, bySlot[i]),
              onDelete: bySlot[i] == null ? null : () => onDelete(bySlot[i]!),
              showDivider: i < WatchManager.alarmSlotCount - 1,
            ),
        ],
      ),
    );
  }
}

class _AlarmRow extends StatelessWidget {
  const _AlarmRow({
    required this.slot,
    required this.alarm,
    required this.onEdit,
    required this.onDelete,
    required this.showDivider,
  });
  final int slot;
  final Alarm? alarm;
  final VoidCallback onEdit;
  final VoidCallback? onDelete;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = alarm;
    final time = a?.labelTime ?? '--:--';
    final subtitle = a == null
        ? 'Tap to add'
        : a.enabled
        ? (a.repeats ? _formatDays(a.weekdays) : 'Once, fires next occurrence')
        : 'Cleared';
    return HealthListTile(
      leadingIcon: Icons.access_time_filled,
      title: time,
      subtitle: subtitle,
      showDivider: showDivider,
      trailing: a == null
          ? Icon(
              CupertinoIcons.chevron_forward,
              size: kIconSizeSmall,
              color: theme.colorScheme.onSurfaceVariant,
            )
          : IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Clear',
              iconSize: kIconSizeSmall,
              color: theme.colorScheme.onSurfaceVariant,
              onPressed: onDelete,
            ),
      onTap: onEdit,
    );
  }

  static String _formatDays(List<bool> days) {
    const labels = ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'];
    final picked = <String>[];
    for (var i = 0; i < days.length && i < labels.length; i++) {
      if (days[i]) picked.add(labels[i]);
    }
    if (picked.length == 7) return 'Every day';
    if (picked.length == 5 &&
        picked.contains('Mo') &&
        picked.contains('Tu') &&
        picked.contains('We') &&
        picked.contains('Th') &&
        picked.contains('Fr')) {
      return 'Weekdays';
    }
    if (picked.length == 2 && picked.contains('Sa') && picked.contains('Su')) {
      return 'Weekends';
    }
    return picked.join(' ');
  }
}

class _AlarmEditor extends StatefulWidget {
  const _AlarmEditor({required this.initial});
  final Alarm initial;

  @override
  State<_AlarmEditor> createState() => _AlarmEditorState();
}

class _AlarmEditorState extends State<_AlarmEditor> {
  late TimeOfDay _time;
  late List<bool> _days;
  late bool _enabled;

  static const _dayLabels = ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'];

  @override
  void initState() {
    super.initState();
    _time = TimeOfDay(hour: widget.initial.hour, minute: widget.initial.minute);
    _days = List<bool>.from(widget.initial.weekdays);
    _enabled = widget.initial.enabled;
  }

  @override
  Widget build(BuildContext context) {
    final hh = _time.hour.toString().padLeft(2, '0');
    final mm = _time.minute.toString().padLeft(2, '0');
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            kCardPadding,
            kSpacingSmall,
            kCardPadding,
            kSectionHeaderPaddingTop,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: kGridSpacing),
              Text(
                widget.initial.enabled
                    ? 'Edit alarm ${widget.initial.slot + 1}'
                    : 'New alarm ${widget.initial.slot + 1}',
                textAlign: TextAlign.center,
                style: AppTextStyles.titleSmall(context),
              ),
              const SizedBox(height: kSectionHeaderPaddingTop),
              Center(
                child: TextButton(
                  onPressed: _pickTime,
                  child: Text(
                    '$hh:$mm',
                    style: TextStyle(
                      fontSize: kDisplayLarge,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: kCardPadding),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < _dayLabels.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: kSpacingMini,
                        ),
                        child: ChoiceChip(
                          label: Text(_dayLabels[i]),
                          selected: _days[i],
                          onSelected: (sel) => setState(() => _days[i] = sel),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: kCardPadding),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _selectPreset(_Preset.weekdays),
                      icon: const Icon(
                        Icons.work_outline,
                        size: kIconSizeSmall,
                      ),
                      label: const Text('Weekdays'),
                    ),
                  ),
                  const SizedBox(width: kSpacingSmall),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _selectPreset(_Preset.weekends),
                      icon: const Icon(
                        Icons.weekend_outlined,
                        size: kIconSizeSmall,
                      ),
                      label: const Text('Weekends'),
                    ),
                  ),
                  const SizedBox(width: kSpacingSmall),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _selectPreset(_Preset.everyday),
                      icon: const Icon(Icons.today, size: kIconSizeSmall),
                      label: const Text('Daily'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: kCardPadding),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Enabled'),
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
              const SizedBox(height: kSpacingSmall),
              PrimaryHealthButton(
                icon: Icons.check,
                label: 'Save to watch',
                onPressed: () {
                  Navigator.pop(
                    context,
                    widget.initial.copyWith(
                      hour: _time.hour,
                      minute: _time.minute,
                      weekdays: _days,
                      enabled: _enabled,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    if (picked != null) setState(() => _time = picked);
  }

  void _selectPreset(_Preset preset) {
    setState(() {
      switch (preset) {
        case _Preset.weekdays:
          _days = [false, true, true, true, true, true, false];
        case _Preset.weekends:
          _days = [true, false, false, false, false, false, true];
        case _Preset.everyday:
          _days = [true, true, true, true, true, true, true];
      }
    });
  }
}

enum _Preset { weekdays, weekends, everyday }

class _NotReady extends StatelessWidget {
  const _NotReady();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(kSectionHeaderPaddingTop),
        child: HealthCard(
          icon: Icons.bluetooth_disabled,
          title: 'Connect your watch',
          caption: 'Connect your watch to manage alarms.',
        ),
      ),
    );
  }
}

class _Unsupported extends StatelessWidget {
  const _Unsupported();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(kSectionHeaderPaddingTop),
        child: HealthCard(
          icon: Icons.notifications_off_outlined,
          title: 'Not supported',
          caption: 'This watch does not advertise clock-alarm support.',
        ),
      ),
    );
  }
}
