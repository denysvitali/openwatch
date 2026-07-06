# OpenWatch UI Refresh Design Spec

This document is the single source of truth for the foundation UI refresh of the OpenWatch Flutter app. It replaces the flat list / generic Material baseline with a card-based, color-coded health dashboard that remains fully offline-first and keeps the existing BLE protocol layer untouched.

## 1. Design principles

- **Card-based surfaces** with generous rounded corners and soft shadows instead of flat lists.
- **Color-coded metrics**: every health category owns one consistent accent hue (heart red, activity green, sleep purple, etc.).
- **Generous whitespace** and breathable vertical rhythm with grouped sections.
- **Live, glanceable data** hero numbers paired with compact unit labels.
- **Cupertino-informed list rows** with circular icon glyphs and subtle dividers.

## 2. Color system

All colors are defined for both light and dark themes. The app uses Material 3 `ColorScheme` seeded from `primaryAccent`, with the semantic health colors surfaced as extension / semantic helpers.

### 2.1 Light

| Token                  | Hex       | Usage                                              |
| ---------------------- | --------- | -------------------------------------------------- |
| `pageBackground`       | `#F5F5F7` | Scaffold background, empty canvas                  |
| `cardSurface`          | `#FFFFFF` | Primary card background                            |
| `cardSurfaceElevated`  | `#FFFFFF` | Elevated / sticky surfaces                         |
| `primaryAccent`        | `#007AFF` | Primary actions, active nav, links                 |
| `heartRed`             | `#FF3B30` | Heart-rate and cardiovascular metrics              |
| `activityGreen`        | `#34C759` | Steps, activity rings, success states              |
| `sleepPurple`          | `#5856D6` | Sleep, recovery, passive night metrics             |
| `mindfulnessTeal`      | `#5AC8FA` | Mindfulness / breathing / stress                   |
| `nutritionOrange`      | `#FF9500` | Calories, nutrition, warnings                      |
| `hydrationBlue`        | `#32ADE6` | Hydration, SpO2-style cool metrics                 |
| `success`              | `#34C759` | Confirmations, online OK                           |
| `warning`              | `#FF9500` | Cautions, pending states                           |
| `error`                | `#FF3B30` | Errors, destructive actions                        |
| `divider`              | `#E5E5EA` | Row / section dividers                             |
| `secondaryText`        | `#8E8E93` | Captions, units, placeholders, inactive labels     |

### 2.2 Dark

| Token                  | Hex       | Usage                                              |
| ---------------------- | --------- | -------------------------------------------------- |
| `pageBackground`       | `#000000` | Scaffold background                                |
| `cardSurface`          | `#1C1C1E` | Primary card background                            |
| `cardSurfaceElevated`  | `#2C2C2E` | Elevated / sticky surfaces                         |
| `primaryAccent`        | `#0A84FF` | Primary actions, active nav                        |
| `heartRed`             | `#FF453A` | Heart-rate and cardiovascular metrics              |
| `activityGreen`        | `#30D158` | Steps, activity, success                           |
| `sleepPurple`          | `#5E5CE6` | Sleep, recovery                                    |
| `mindfulnessTeal`      | `#64D2FF` | Mindfulness / breathing / stress                   |
| `nutritionOrange`      | `#FF9F0A` | Calories, nutrition, warnings                      |
| `hydrationBlue`        | `#32ADE6` | Hydration / cool metrics                           |
| `success`              | `#30D158` | Confirmations                                      |
| `warning`              | `#FF9F0A` | Cautions                                           |
| `error`                | `#FF453A` | Errors, destructive                                |
| `divider`              | `#38383A` | Dividers                                           |
| `secondaryText`        | `#8E8E93` | Captions, units, inactive labels                   |

## 3. Typography

Tokens are mapped to the closest Material 3 text theme style and then tweaked.

| Token             | Material style     | Size   | Weight       | Line height | Letter spacing | Color / notes                |
| ----------------- | ------------------ | ------ | ------------ | ----------- | -------------- | ---------------------------- |
| `heroNumber`      | `displayLarge`     | 56sp   | `w700`       | 1.0         | -0.02          | On-surface, metric hero      |
| `heroUnit`        | `titleMedium`      | 20sp   | `w600`       | 1.2         | 0              | `secondaryText`              |
| `pageTitle`       | `headlineSmall`    | 28sp   | `w700`       | 1.2         | 0              | On-surface                   |
| `cardTitle`       | `titleLarge`       | 20sp   | `w700`       | 1.25        | 0              | On-surface                   |
| `cardValue`       | `headlineMedium`   | 32sp   | `w700`       | 1.0         | 0              | On-surface / metric color    |
| `cardUnit`        | `labelLarge`       | 14sp   | `w600`       | 1.0         | 0              | `secondaryText`              |
| `body`            | `bodyLarge`        | 17sp   | `w400`       | 1.35        | 0              | On-surface                   |
| `caption`         | `bodySmall`        | 13sp   | `w400`       | 1.3         | 0              | `secondaryText`              |
| `button`          | `labelLarge`       | 16sp   | `w600`       | 1.25        | 0              | White / on-primary           |
| `overline`        | `labelSmall`       | 11sp   | `w700`       | 1.0         | 0.8            | Uppercase, `secondaryText`   |

## 4. Components

### 4.1 HealthCard

- Rounded rectangle with `borderRadius: 20`.
- Padding `18` on all sides.
- Optional `LinearGradient` background from the metric color at `0.14` alpha to `0.06` alpha.
- Leading icon: `28dp` icon centered inside a `48dp` circular `Container` filled with metric color at `0.14` alpha.
- Title uses `cardTitle`.
- Value + unit are baseline-aligned: value uses `cardValue`, unit uses `cardUnit`.
- Caption uses `caption`.
- Trailing widget constrained to `40dp` width.
- Elevation `0`; elevated variant adds a soft `BoxShadow` (`primaryAccent` at `0.08` opacity, `blurRadius: 16`, offset `0, 6`).

### 4.2 MetricGrid

- A `Sliver` / `GridView` with 2 columns.
- `crossAxisSpacing: 12`, `mainAxisSpacing: 12`.
- `childAspectRatio: 1.45`.
- `maxCrossAxisExtent: 220`.
- Wraps `HealthCard` tiles.

### 4.3 HealthListTile

- Cupertino-style row.
- Padding `16dp` vertical / `18dp` horizontal.
- Leading: `38dp` circular `Container` tinted with metric color at `0.14` alpha, holding a `20dp` icon in metric color.
- Title uses `body` with `FontWeight.w600`.
- Subtitle uses `caption`.
- Trailing `Row`: value text in `cardValue` tinted `secondaryText`, unit in `caption`, and a `20dp` chevron in `secondaryText`.
- Divider `1dp`, indented `56dp`, in `divider` color.

### 4.4 HealthSectionHeader

- Padding `24dp` top / `8dp` bottom / `18dp` horizontal.
- Title uses `pageTitle` at `22sp`.
- Optional `TextButton` trailing with `labelSmall` primary color and a `'Show All'` label.

### 4.5 StatusPill

- Height `24dp`, horizontal padding `10dp`, `borderRadius: 12dp`.
- Background uses the status color at `0.12` alpha.
- `12dp` status icon, `6dp` spacing, label uses `labelSmall` in the same status color.
- Replaces / extends the previous `SyncStatusPill` so it can be reused for signal strength, update availability, cloud status, etc.

### 4.6 PrimaryHealthButton

- Minimum height `54dp`, `borderRadius: 16dp`, horizontal padding `24dp`.
- Background `primaryAccent`, foreground white.
- Text uses `button`.
- Optional `48dp` leading icon.
- Shadow: `primaryAccent` at `0.16` alpha, `blurRadius: 12`, offset `0, 4`.

### 4.7 AnimatedHeartBadge

- `48dp` circular `Container` filled with `heartRed` at `0.14` alpha.
- `28dp` `Icon` (`CupertinoIcons.heart_fill`) in `heartRed`.
- `ScaleTransition` pulsing between `1.0` and `1.18` with `Curves.easeInOut` over `900ms` repeating.
- Optional shimmer overlay.

## 5. Navigation

### 5.1 Tab order

| Index | Label     | Notes                                              |
| ----- | --------- | -------------------------------------------------- |
| 0     | Summary   | Was "dashboard" / "Device"                         |
| 1     | Health    | Live metrics and measurement controls              |
| 2     | History   | Was not in the bottom tab bar; now promoted        |
| 3     | Settings  | Notifications moved into Settings as a subsection  |

### 5.2 Old route mapping

| Old route        | New location                                  |
| ---------------- | --------------------------------------------- |
| `/dashboard`     | `/summary` (still implemented by `DashboardScreen`) |
| `/health`        | `/health`                                     |
| `/notifications` | Moved into Settings as a subsection           |
| `/history`       | `/history`                                    |

### 5.3 Icons

| Tab     | Material outlined              | Material filled              | Cupertino                    |
| ------- | ------------------------------ | ---------------------------- | ---------------------------- |
| Summary | `Icons.watch_outlined`         | `Icons.watch_rounded`        | `CupertinoIcons.watch_square`|
| Health  | `Icons.favorite_outline`       | `Icons.favorite`             | `CupertinoIcons.heart`       |
| History | `Icons.show_chart_outlined`    | `Icons.show_chart`           | `CupertinoIcons.chart_bar_alt_fill` |
| Settings| `Icons.settings_outlined`      | `Icons.settings`             | `CupertinoIcons.gear_alt`    |

### 5.4 Styling

- **Selected**: `primaryAccent` fill icon inside an indicator at `0.12` alpha; label uses `labelSmall` `FontWeight.w700` in `primaryAccent`.
- **Unselected**: `secondaryText` icon at `24dp`; label uses `labelSmall` `FontWeight.w500` in `secondaryText`.

### 5.5 Responsive behavior

- Screens narrower than `720dp` show a bottom `NavigationBar`.
- Wider screens show a fixed `NavigationRail` on the left with the same destinations and labels.
- The shell itself has no `AppBar`; each page provides its own app bar or header as needed.

## 6. Screen plans

### 6.1 Scan

- Keep the scanning flow but surface it as a full-bleed welcome page.
- Replace the current `Card` status block with a centered hero `HealthCard`.
- Use `PrimaryHealthButton` for Scan / Stop actions.
- Adopt `HealthListTile` for discovered devices with a signal `StatusPill`.
- Keep the auto-reconnect banner at the top.

### 6.2 Summary (formerly Dashboard)

- Rename on screen and in the tab bar to **Summary**.
- Stack the device hero as a full-width `HealthCard`.
- Follow with a `MetricGrid` of Steps / Heart / Energy / Distance.
- Add a Recent Activity `HealthCard` with mini sparklines.
- Replace quick action buttons with a `PrimaryHealthButton` grid.
- Surface armed alarms via `HealthListTile` rows.

### 6.3 Health

- Lead with the heart-rate `HealthCard` as a full-width hero, using `AnimatedHeartBadge` while measuring.
- Convert the available-metrics list to `HealthListTile` rows inside a single `cardSurface` group with `HealthSectionHeader`.
- Color-code each metric by category.
- Move Start / Stop controls into trailing controls.

### 6.4 History

- Use `HealthSectionHeader` for **Local history** and **Last 7 days**.
- Wrap overview in `HealthCard`.
- Render stat grid through `MetricGrid`.
- Replace the day selector with a Cupertino-style segmented control.
- Use `HealthListTile` for metric rows in daily detail.
- Keep chart cards inside `cardSurface` containers with `20dp` radius.

### 6.5 Notifications

- Move from a standalone tab into a new Settings subsection.
- Redesign as a `HealthListTile` group with category icons (Calls, Messages, Apps) and circular colored glyphs.
- Keep the disabled switches until backend support lands.

### 6.6 Settings

- Group all rows by `HealthSectionHeader` sections: Device, Cloud, Diagnostics, About.
- Replace plain `ListTile` with `HealthListTile` for every actionable row.
- Keep destructive actions in `error` color.
- Use `StatusPill` for cloud and connection status.

### 6.7 Alarms

- Add a sticky `HealthSectionHeader`.
- Render each alarm slot as a `HealthListTile` with a leading clock icon in `activityGreen`.
- Keep the FAB but restyle it as an extended `PrimaryHealthButton` at the bottom.

### 6.8 Firmware

- Restructure as a stack of `HealthCard`s: current version, local stored images list, OTA progress.
- Use `PrimaryHealthButton` for Fetch and Flash actions.
- Use `StatusPill` for update availability.
- Keep the progress indicator inside the card.

### 6.9 Logs

- Turn the diagnostics screen into a Summary-style list with a `HealthCard` for OTel status and a `HealthSectionHeader` for the log stream.
- Keep the scrolling log list, but style the empty / copy / clear toolbar with icon buttons.

## 7. Implementation notes

- All shared widgets live under `lib/features/widgets/` and are exported by `lib/features/widgets/health_widgets.dart`.
- The theme is implemented in `lib/main.dart` using Material 3, with `ColorScheme` built from the design tokens.
- Component themes for `Card`, `FilledButton`, `OutlinedButton`, `IconButton`, `NavigationBar`, `NavigationRail`, `ListTile`, `Chip`, `AppBar`, `Divider`, and `SnackBar` are derived from the design system.
- No screen files were modified in this foundation pass; this design doc and the widget / theme / shell changes prepare the components those screens will consume in follow-up work.
