import 'package:tomeui/tomeui.dart';

/// The dressing a list row wears: the theme's surface at a tighter radius —
/// the full card radius on a 28px row reads as a lozenge.
class RowSurface extends StatelessWidget {
  const RowSurface({
    required this.swatch,
    required this.variant,
    required this.child,
    super.key,
  });

  final SemanticSwatch swatch;
  final SurfaceVariant variant;
  final Widget child;

  static const _radius = BorderRadius.all(Radius.circular(4));

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final style = theme.widgets.surface
        .resolve(swatch, variant)
        .copyWith(radius: _radius);
    return Surface.custom(style: style, child: child);
  }
}
