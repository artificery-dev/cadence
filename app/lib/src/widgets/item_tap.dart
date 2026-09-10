import 'package:cadence_media/cadence_media.dart';
import 'package:flutter/foundation.dart';
import 'package:tomeui/tomeui.dart';

import 'shelf_actions.dart';

/// One tap grammar for every shelf, on every platform.
///
/// On desktop, a single click shows the item's information in the side
/// panel and a double click sends it to the deck — unless the queue is
/// the panel showing, in which case a double click on an audio item
/// quietly joins it to the queue instead. On touch, a tap sends the
/// item straight to the deck and a long press inspects — the pointing
/// paradigms differ, the verbs don't.
///
/// [onOpen] is the site's own "to the deck" verb (play, play-collection,
/// open); the inspect side comes from the [ShelfActions] above, so views
/// carry no wiring for it. The inspected item's tap target wears a
/// subtle primary wash, so the shelf shows which tile the panel is
/// talking about.
class ItemTap extends StatelessWidget {
  const ItemTap({
    required this.item,
    required this.onOpen,
    required this.child,
    this.onHover,
    super.key,
  });

  final MediaItem item;
  final VoidCallback onOpen;
  final Widget child;

  /// For rows that dress themselves on hover.
  final ValueChanged<bool>? onHover;

  /// On the selection wash's box, so tests can find the one dressed
  /// tile without chasing paint.
  static const washKey = Key('item-tap-wash');

  static bool get _touch => switch (defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => true,
    _ => false,
  };

  @override
  Widget build(BuildContext context) {
    final actions = ShelfActions.maybeOf(context);
    final scaffold = ScaffoldStateProvider.maybeOf(context);

    void open() {
      // The queue showing is an invitation: audio joins it rather than
      // seizing the deck. Showing means the panel is open with its
      // Queue tab in front.
      final queueShowing =
          (scaffold?.trailing.open ?? false) && (actions?.queueTab ?? false);
      if (queueShowing && actions != null) {
        if (item.metadata case AudioMetadata()) {
          actions.player.enqueue([
            AudioItem(
              id: item.id,
              fileId: item.fileId,
              path: item.path,
              metadata: item.metadata as AudioMetadata,
              tags: item.tags,
            ),
          ]);
          return;
        }
      }
      onOpen();
    }

    void inspect() {
      if (actions == null) return;
      actions.inspect(item);
      scaffold?.open(ScaffoldSide.trailing);
    }

    // The one on the panel wears a quiet primary wash — a step below
    // the "on the deck" dress, so selected and playing stay tellable.
    // Paint only: a Surface here would bring its own text defaults and
    // nudge tight grid cells into overflow.
    final selected = actions?.inspected?.id == item.id;
    final wash = selected
        ? ThemeProvider.of(context).widgets.surface
              .resolve(SemanticSwatch.primary, SurfaceVariant.subtle)
              .fill
        : null;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: onHover == null ? null : (_) => onHover!(true),
      onExit: onHover == null ? null : (_) => onHover!(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _touch ? open : inspect,
        onDoubleTap: _touch ? null : open,
        onLongPress: _touch ? inspect : null,
        child: wash != null
            ? DecoratedBox(
                key: washKey,
                decoration: BoxDecoration(
                  color: wash,
                  borderRadius: const BorderRadius.all(Radius.circular(4)),
                ),
                child: child,
              )
            : child,
      ),
    );
  }
}
