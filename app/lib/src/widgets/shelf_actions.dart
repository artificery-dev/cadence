import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import '../model/player.dart';

/// The shell's answers to what a tap on a shelf means, hung above every
/// view: who the deck is, how to ask for an item's page in the side
/// panel, and which item is on it now. [ItemTap] widgets read this so
/// the views themselves never carry the wiring.
class ShelfActions extends InheritedWidget {
  const ShelfActions({
    required this.player,
    required this.inspect,
    required this.inspected,
    required this.queueTab,
    required this.revealQueue,
    required super.child,
    super.key,
  });

  final PlaybackController player;

  /// Show this item's information in the side panel.
  final void Function(MediaItem item) inspect;

  /// The item the panel's Info tab holds, or null when there is none.
  final MediaItem? inspected;

  /// Whether the panel's Queue tab fronts — what "the queue is showing"
  /// means once the panel is open.
  final bool queueTab;

  /// Front the Queue tab — the now-playing well asks for it by name.
  final VoidCallback revealQueue;

  static ShelfActions? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShelfActions>();

  @override
  bool updateShouldNotify(ShelfActions oldWidget) =>
      inspected?.id != oldWidget.inspected?.id ||
      queueTab != oldWidget.queueTab;
}
