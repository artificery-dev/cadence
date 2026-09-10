import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import '../model/player.dart';
import 'item_inspector.dart';
import 'queue_panel.dart';

/// The trailing sidebar's two tenants under one roof: Info, then Queue,
/// behind a strip that always stands — reading about one thing never
/// locks the queue away, and the empty Info tab says how to fill it.
/// The inspector's X lets the inspection go and fronts the queue.
class TrailingPanel extends StatelessWidget {
  const TrailingPanel({
    required this.player,
    required this.inspected,
    required this.infoTab,
    required this.onTab,
    required this.onCloseInspector,
    required this.onAddToCollection,
    super.key,
  });

  final PlaybackController player;

  /// The item the Info tab holds, or null when it stands empty.
  final MediaItem? inspected;

  /// Which tab fronts — true is Info.
  final bool infoTab;
  final ValueChanged<bool> onTab;

  final VoidCallback onCloseInspector;
  final VoidCallback onAddToCollection;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final item = inspected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            theme.space.x3,
            theme.space.x2,
            theme.space.x3,
            theme.space.x1,
          ),
          child: SegmentedControl<bool>(
            value: infoTab,
            onChanged: onTab,
            segments: const [
              SegmentOption(value: true, label: Text('Info')),
              SegmentOption(value: false, label: Text('Queue')),
            ],
          ),
        ),
        Expanded(
          child: !infoTab
              ? QueuePanel(player: player)
              : item != null
              ? ItemInspector(
                  item: item,
                  player: player,
                  onClose: onCloseInspector,
                  onAddToCollection: onAddToCollection,
                )
              : const Center(
                  child: EmptyState(
                    icon: LucideIcons.info,
                    title: TitleText('Nothing inspected'),
                    message: BodyText('Choose an item on any shelf.'),
                  ),
                ),
        ),
      ],
    );
  }
}
