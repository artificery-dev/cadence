import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import '../model/player.dart';
import '../util/format.dart';
import '../widgets/row_surface.dart';
import '../widgets/item_tap.dart';

/// One collection: its rows in laid order, any kind side by side — a
/// playlist, a reading order, a watch order. Audio rows put the
/// collection's audio run on the deck starting there (ordered
/// collections play as laid down — the transport's shuffle and repeat
/// stand down while one reigns); every other kind goes to the deck too,
/// which wears that kind's face.
class CollectionView extends StatelessWidget {
  const CollectionView({
    required this.player,
    required this.collection,
    required this.items,
    super.key,
  });

  final PlaybackController player;
  final CollectionRow collection;
  final List<MediaItem> items;

  /// The collection's audio, in laid order — what a tap on any audio row
  /// deals to the deck.
  List<AudioItem> get _audioRun => [
    for (final item in items)
      if (item.metadata case final AudioMetadata metadata)
        AudioItem(
          id: item.id,
          fileId: item.fileId,
          path: item.path,
          metadata: metadata,
          tags: item.tags,
        ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            theme.space.x4,
            theme.space.x4,
            theme.space.x4,
            theme.space.x2,
          ),
          child: Row(
            spacing: theme.space.x2,
            children: [
              const Icon(LucideIcons.list, size: 18),
              TitleText(collection.name),
              const Spacer(),
              CaptionText('${items.length} items'),
            ],
          ),
        ),
        const Divider(),
        Expanded(
          child: items.isEmpty
              ? const Center(
                  child: EmptyState(
                    icon: LucideIcons.list,
                    title: TitleText('Nothing here yet'),
                    message: BodyText('This collection is waiting for items.'),
                  ),
                )
              : ListenableBuilder(
                  listenable: player,
                  builder: (context, _) => ListView.separated(
                    // Twice the row gap above; the sides' own step
                    // below, where the list ends.
                    padding: EdgeInsets.fromLTRB(
                      theme.space.x3,
                      theme.space.x2,
                      theme.space.x3,
                      theme.space.x3,
                    ),
                    itemCount: items.length,
                    separatorBuilder: (context, _) =>
                        SizedBox(height: theme.space.x1),
                    itemBuilder: (context, index) => _CollectionRow(
                      item: items[index],
                      audioRun: _audioRun,
                      player: player,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _CollectionRow extends StatefulWidget {
  const _CollectionRow({
    required this.item,
    required this.audioRun,
    required this.player,
  });

  final MediaItem item;
  final List<AudioItem> audioRun;
  final PlaybackController player;

  @override
  State<_CollectionRow> createState() => _CollectionRowState();
}

class _CollectionRowState extends State<_CollectionRow> {
  bool _hover = false;

  static const _glyphs = {
    MediaKind.audio: LucideIcons.music4,
    MediaKind.video: LucideIcons.film,
    MediaKind.document: LucideIcons.bookOpen,
    MediaKind.image: LucideIcons.image,
  };

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final palette = theme.palette;
    final metadata = widget.item.metadata;
    final secondary = palette.text.withValues(alpha: theme.opacities.secondary);

    // What the row says, kind by kind: a name, a credit, and the
    // measure that kind is measured in.
    final (title, byline, trailing) = switch (metadata) {
      AudioMetadata(:final title, :final artist, :final duration) => (
        title,
        artist ?? '',
        formatClock(duration ?? Duration.zero),
      ),
      VideoMetadata(:final title, :final series, :final duration) => (
        title,
        series ?? '',
        formatClock(duration ?? Duration.zero),
      ),
      DocumentMetadata(:final title, :final author, :final pageCount) => (
        title,
        author ?? '',
        pageCount == null ? '' : '$pageCount pp',
      ),
      ImageMetadata(:final title, :final width, :final height) => (
        title ?? '',
        '',
        width != null && height != null ? '$width×$height' : '',
      ),
    };

    final playable = metadata is AudioMetadata;
    final current = playable
        ? widget.player.opened == null &&
              widget.player.current?.id == widget.item.id
        : widget.player.opened?.id == widget.item.id;

    final content = Padding(
      padding: EdgeInsets.symmetric(horizontal: theme.space.x3),
      child: SizedBox(
        height: 34,
        child: Row(
          spacing: theme.space.x2,
          children: [
            Icon(
              current ? LucideIcons.audioLines : _glyphs[metadata.kind],
              size: 14,
              color: current ? palette.primary.s400 : secondary,
            ),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.bodySmall.copyWith(
                  fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            Text(
              byline,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.typography.caption.copyWith(color: secondary),
            ),
            Text(
              trailing,
              style: theme.typography.code.copyWith(
                fontSize: theme.typography.caption.fontSize,
                color: secondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );

    final Widget dressed;
    if (current) {
      dressed = RowSurface(
        swatch: SemanticSwatch.primary,
        variant: SurfaceVariant.soft,
        child: content,
      );
    } else if (_hover) {
      dressed = RowSurface(
        swatch: SemanticSwatch.neutral,
        variant: SurfaceVariant.subtle,
        child: content,
      );
    } else {
      dressed = content;
    }

    // Audio joins the collection's run on the deck; everything else
    // takes the deck alone, wearing its own face.
    return ItemTap(
      item: widget.item,
      onOpen: playable
          ? () => widget.player.playCollection(
              widget.audioRun,
              startAt: widget.audioRun.firstWhere(
                (a) => a.id == widget.item.id,
              ),
            )
          : () => widget.player.open(widget.item),
      onHover: (hover) => setState(() => _hover = hover),
      child: dressed,
    );
  }
}
