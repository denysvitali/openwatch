import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/app_providers.dart';
import '../../core/services/watch_manager.dart';
import '../../core/ui/ui_constants.dart';
import '../widgets/health_widgets.dart';

/// Wristband sensor settings: HR auto-measure interval, enable toggle,
/// and optional low/high alarm thresholds.
///
/// Changes are persisted locally via [SettingsService] and can be
/// pushed to the watch with the "Apply to device" action.
class SensorSettingsScreen extends ConsumerWidget {
  const SensorSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final settingsNotifier = ref.read(settingsProvider.notifier);
    final manager = ref.watch(watchManagerProvider);
    final ready = manager.isReady;
    final caps = manager.capabilities;
    final hrSupported = caps.heart;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Sensor settings')),
      body: MaxWidthContainer(
        child: ListView(
          padding: const EdgeInsets.only(bottom: kScreenPaddingBottom),
          children: [
            if (!hrSupported)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: kCardPadding,
                  vertical: kSpacingSmall,
                ),
                child: HealthCard(
                  icon: Icons.info_outline,
                  metricColor: theme.colorScheme.error,
                  caption: 'Heart rate not supported on this device',
                  trailing: StatusPill(
                    icon: Icons.error_outline,
                    label: 'Unsupported',
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            const HealthSectionHeader(title: 'Heart rate'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
              child: InsetCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HealthListTile(
                      title: 'Auto-measure',
                      subtitle: 'Periodic background readings',
                      leadingIcon: Icons.favorite,
                      trailing: Switch(
                        value: settings.hrAutoMeasureEnabled,
                        onChanged: settingsNotifier.setHrAutoMeasure,
                      ),
                      onTap: () => settingsNotifier.setHrAutoMeasure(
                        !settings.hrAutoMeasureEnabled,
                      ),
                    ),
                    HealthListTile(
                      title: 'Measurement interval',
                      subtitle: '${settings.hrIntervalMinutes} minutes',
                      leadingIcon: Icons.timer,
                      showDivider: false,
                      onTap: null,
                    ),
                    // Full-width slider below the label so neither the title
                    // nor the control gets squeezed on narrow screens / at
                    // large text scale.
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: kListTilePaddingH,
                      ),
                      child: Slider(
                        value: settings.hrIntervalMinutes.toDouble(),
                        min: 1,
                        max: 60,
                        divisions: 59,
                        label: '${settings.hrIntervalMinutes} min',
                        onChanged: settings.hrAutoMeasureEnabled
                            ? (v) => settingsNotifier.setHrInterval(v.round())
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const HealthSectionHeader(title: 'Alarm thresholds'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: kCardPadding),
              child: InsetCard(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _AlarmFieldTile(
                      title: 'Low HR alarm',
                      subtitle: '0 = disabled',
                      icon: Icons.trending_down,
                      value: settings.hrLowAlarm,
                      onSubmitted: settingsNotifier.setHrLowAlarm,
                    ),
                    _AlarmFieldTile(
                      title: 'High HR alarm',
                      subtitle: '0 = disabled',
                      icon: Icons.trending_up,
                      value: settings.hrHighAlarm,
                      onSubmitted: settingsNotifier.setHrHighAlarm,
                      showDivider: false,
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                kCardPadding,
                kGridSpacing,
                kCardPadding,
                0,
              ),
              child: PrimaryHealthButton(
                label: 'Apply to device now',
                icon: Icons.watch,
                onPressed: (ready && hrSupported)
                    ? () => _applyToDevice(context, ref, manager)
                    : null,
              ),
            ),
            if (!ready)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  kCardPadding,
                  kGridSpacing,
                  kCardPadding,
                  0,
                ),
                child: StatusPill(
                  icon: Icons.bluetooth_disabled,
                  label: 'Connect a watch first',
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else if (!hrSupported)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  kCardPadding,
                  kGridSpacing,
                  kCardPadding,
                  0,
                ),
                child: StatusPill(
                  icon: Icons.error_outline,
                  label: 'HR not supported on this device',
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _applyToDevice(
    BuildContext context,
    WidgetRef ref,
    WatchManager manager,
  ) async {
    final settings = ref.read(settingsProvider);
    try {
      await manager.applyHeartRateSettings(
        enabled: settings.hrAutoMeasureEnabled,
        interval: settings.hrIntervalMinutes,
        tooLow: settings.hrLowAlarm,
        tooHigh: settings.hrHighAlarm,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sensor settings applied to watch')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to apply: $e')));
      }
    }
  }
}

class _AlarmFieldTile extends StatefulWidget {
  const _AlarmFieldTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.value,
    required this.onSubmitted,
    this.showDivider = true,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final int value;
  final ValueChanged<int> onSubmitted;
  final bool showDivider;

  @override
  State<_AlarmFieldTile> createState() => _AlarmFieldTileState();
}

class _AlarmFieldTileState extends State<_AlarmFieldTile> {
  late final TextEditingController _controller;
  final FocusNode _focus = FocusNode();
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
  }

  @override
  void didUpdateWidget(_AlarmFieldTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The backing settings hydrate asynchronously; reflect the incoming
    // value only when the user is not mid-edit, so `initialValue`'s
    // first-build-only limitation no longer strands stale defaults.
    if (widget.value != oldWidget.value &&
        !_focus.hasFocus &&
        _controller.text != widget.value.toString()) {
      _controller.text = widget.value.toString();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit(String v) {
    final parsed = int.tryParse(v);
    if (parsed != null && parsed >= 0 && parsed <= 255) {
      setState(() => _error = null);
      widget.onSubmitted(parsed);
    } else {
      setState(() => _error = '0–255');
    }
  }

  @override
  Widget build(BuildContext context) {
    return HealthListTile(
      title: widget.title,
      subtitle: widget.subtitle,
      leadingIcon: widget.icon,
      control: SizedBox(
        width: 96,
        child: TextField(
          controller: _controller,
          focusNode: _focus,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          decoration: InputDecoration(
            suffixText: 'bpm',
            isDense: true,
            errorText: _error,
          ),
          onSubmitted: _submit,
        ),
      ),
      onTap: null,
      showDivider: widget.showDivider,
    );
  }
}
