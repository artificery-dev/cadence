import 'package:cadence_assets/cadence_assets.dart';
import 'package:tomeui/tomeui.dart';

import '../data/hosting.dart';
import '../model/settings.dart';
import '../version.dart';

/// Settings, grouped into cards — Appearance, Library, Background, and
/// About. Playback returns when there is a real engine to configure;
/// misleading knobs are worse than none.
class SettingsView extends StatelessWidget {
  const SettingsView({required this.settings, this.hosting, super.key});

  final SettingsModel settings;

  /// Who runs the library and the switch between them; null when the app
  /// was booted without a choice to offer.
  final HostingController? hosting;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final dark = theme.palette.brightness == Brightness.dark;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => SingleChildScrollView(
        padding: EdgeInsets.all(theme.space.x8),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const HeadlineText('Settings'),
                Spacing(SpaceStep.x5),
                Card(
                  header: const TitleText('Appearance'),
                  content: Column(
                    children: [
                      _SettingRow(
                        label: 'Theme',
                        caption: 'Follows your desktop unless told otherwise.',
                        control: SegmentedControl<ThemePreference>(
                          value: settings.themePreference,
                          onChanged: (value) =>
                              settings.themePreference = value,
                          segments: [
                            SegmentOption(
                              value: ThemePreference.system,
                              label: const Text('System'),
                              leading: Icon(theme.icons.systemMode, size: 14),
                            ),
                            SegmentOption(
                              value: ThemePreference.light,
                              label: const Text('Light'),
                              leading: Icon(theme.icons.lightMode, size: 14),
                            ),
                            SegmentOption(
                              value: ThemePreference.dark,
                              label: const Text('Dark'),
                              leading: Icon(theme.icons.darkMode, size: 14),
                            ),
                          ],
                        ),
                      ),
                      Spacing(SpaceStep.x4),
                      _SettingRow(
                        label: 'Primary',
                        caption: 'The colour the transport answers in.',
                        control: _SwatchSelect(
                          value: settings.primary,
                          stop: dark ? 400 : 500,
                          onChanged: (value) => settings.primary = value,
                        ),
                      ),
                      Spacing(SpaceStep.x4),
                      _SettingRow(
                        label: 'Accent',
                        caption:
                            "The LCD's phosphor — the deck's second "
                            'voice.',
                        // The other mid shade, so the two rows read as two
                        // rows even wearing the same set.
                        control: _SwatchSelect(
                          value: settings.accent,
                          stop: dark ? 500 : 400,
                          onChanged: (value) => settings.accent = value,
                        ),
                      ),
                      Spacing(SpaceStep.x4),
                      _SettingRow(
                        label: 'Neutral',
                        caption: 'What the chrome is cut from.',
                        // Deep enough to read as chrome, shallow enough
                        // that the greys still tell apart.
                        control: _SwatchSelect(
                          value: settings.neutral,
                          stop: dark ? 600 : 300,
                          onChanged: (value) => settings.neutral = value,
                        ),
                      ),
                    ],
                  ),
                ),
                Spacing(SpaceStep.x4),
                Card(
                  header: const TitleText('Library'),
                  content: _SettingRow(
                    label: 'Watch folders',
                    caption:
                        'The scanner keeps an eye on library folders '
                        'and rescans what changes.',
                    control: Switch<bool>(
                      value: settings.watchFolders,
                      onChanged: (value) => settings.watchFolders = value,
                    ),
                  ),
                ),
                Spacing(SpaceStep.x4),
                Card(
                  header: const TitleText('Background'),
                  content: _BackgroundRow(hosting: hosting),
                ),
                Spacing(SpaceStep.x4),
                Card(
                  header: const TitleText('About'),
                  content: Row(
                    children: [
                      SizedBox.square(
                        dimension: 48,
                        child: Image.asset(
                          CadenceAssets.icon,
                          package: CadenceAssets.package,
                          filterQuality: FilterQuality.medium,
                        ),
                      ),
                      Spacing(SpaceStep.x4, axis: Axis.horizontal),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            BodyText('Cadence $appVersion'),
                            CaptionText(
                              'Built on Tome UI. Fully skinnable someday — '
                              'we remember where we came from.',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The switch that moves the library out to `cadenced` and back, with
/// the state of the move beneath it: why it cannot be offered, that it is
/// under way, or what went wrong the last time.
class _BackgroundRow extends StatelessWidget {
  const _BackgroundRow({required this.hosting});

  final HostingController? hosting;

  static const _promise =
      'Installs cadenced as your user service and hands it the library, '
      'so scanning and folder watching carry on while Cadence is closed.';

  @override
  Widget build(BuildContext context) {
    final hosting = this.hosting;
    if (hosting == null) {
      return const _SettingRow(
        label: 'Allow Cadence to run in the background',
        caption: 'Not available the way Cadence was started.',
        control: Switch<bool>(value: false, enabled: false),
      );
    }
    return ListenableBuilder(
      listenable: Listenable.merge([hosting, hosting.connection]),
      builder: (context, _) {
        final reason = hosting.unavailableReason;
        final error = hosting.error;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SettingRow(
              label: 'Allow Cadence to run in the background',
              caption: reason ?? _promise,
              control: Switch<bool>(
                value: hosting.background,
                enabled: reason == null && !hosting.busy,
                onChanged: (value) => hosting.setBackground(value),
              ),
            ),
            Spacing(SpaceStep.x2),
            if (hosting.busy)
              CaptionText(
                hosting.background
                    ? 'Bringing the library back inside Cadence…'
                    : 'Handing the library to the background service…',
              )
            else if (error != null)
              CaptionText(
                error,
                swatch: SemanticSwatch.error,
                emphasis: TextEmphasis.full,
              )
            else
              CaptionText(hosting.connection.hosting.label),
          ],
        );
      },
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.label, required this.control, this.caption});

  final String label;
  final String? caption;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BodyText(label),
              if (caption != null)
                CaptionText(caption!, emphasis: TextEmphasis.secondary),
            ],
          ),
        ),
        Spacing(SpaceStep.x4, axis: Axis.horizontal),
        control,
      ],
    );
  }
}

/// A select over one of tomeui's colour-set rosters, each option wearing a
/// chip of the swatch itself.
class _SwatchSelect extends StatelessWidget {
  const _SwatchSelect({
    required this.value,
    required this.stop,
    required this.onChanged,
  });

  final PaletteSet value;
  final ValueChanged<PaletteSet> onChanged;

  /// The ramp stop the chip shows — each slot picks the shade it will
  /// actually wear.
  final int stop;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 160,
      child: Select<PaletteSet>(
        value: value,
        onChanged: onChanged,
        options: [
          for (final set in PaletteSet.values)
            SelectOption(
              value: set,
              label: Text(set.label),
              leading: _SwatchDot(set.swatch, stop: stop),
            ),
        ],
      ),
    );
  }
}

/// A little chip of the swatch itself, beside its name in the select. The
/// hairline ring keeps a chip visible when it lands near the card's own
/// colour.
class _SwatchDot extends StatelessWidget {
  const _SwatchDot(this.swatch, {required this.stop});

  final Swatch swatch;
  final int stop;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return SizedBox.square(
      dimension: 12,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: swatch[stop],
          shape: BoxShape.circle,
          border: Border.all(
            color: theme.palette.text.withValues(
              alpha: theme.opacities.divider,
            ),
          ),
        ),
      ),
    );
  }
}
