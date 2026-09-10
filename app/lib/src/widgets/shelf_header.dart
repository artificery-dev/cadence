import 'package:tomeui/tomeui.dart';

/// The strip every shelf wears above its content: facet segments and
/// pickers at the start, toggles and captions at the end — one padding,
/// one centre line, every page. Views stop inventing their own margins;
/// the selectors land in the same place wherever you are.
class ShelfHeader extends StatelessWidget {
  const ShelfHeader({
    this.leading = const [],
    this.trailing = const [],
    super.key,
  });

  final List<Widget> leading;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        theme.space.x4,
        theme.space.x3,
        theme.space.x4,
        theme.space.x3,
      ),
      child: Row(
        spacing: theme.space.x3,
        children: [...leading, const Spacer(), ...trailing],
      ),
    );
  }
}
