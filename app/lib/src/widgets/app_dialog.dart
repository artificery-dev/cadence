import 'package:tomeui/tomeui.dart';

/// The house dialog dress: the glyph beside the title, a close button
/// holding the top right corner the way a window keeps its own, and a
/// rule under the header before the body speaks. Actions, when a dialog
/// has an affirmative, sit where the eye finishes — the header's close
/// is every dialog's way out, so no Cancel rides beside them.
class AppDialog extends StatelessWidget {
  const AppDialog({
    required this.icon,
    required this.title,
    this.swatch = SemanticSwatch.primary,
    this.content,
    this.actions = const [],
    super.key,
  });

  /// The glyph beside the title, wearing [swatch] — what turns a dialog
  /// into a warning without a word of it being said.
  final IconData icon;
  final Widget title;
  final SemanticSwatch swatch;
  final Widget? content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return Dialog(
      title: Row(
        children: [
          Icon(
            icon,
            size: theme.sizes.iconLarge,
            color: theme.widgets.surface
                .resolve(swatch, SurfaceVariant.solid)
                .fill,
          ),
          Spacing(SpaceStep.x2, axis: Axis.horizontal),
          Expanded(child: title),
          Tooltip(
            message: const Text('Close'),
            child: Button(
              onPressed: () => Navigator.of(context).pop(),
              variant: SurfaceVariant.ghost,
              swatch: SemanticSwatch.neutral,
              center: Icon(theme.icons.close, size: 14),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(),
          if (content != null) ...[Spacing(SpaceStep.x3), content!],
        ],
      ),
      actions: actions,
    );
  }
}
