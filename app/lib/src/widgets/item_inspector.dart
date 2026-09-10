import 'package:cadence_media/cadence_media.dart';
import 'package:tomeui/tomeui.dart';

import '../model/player.dart';
import '../util/format.dart';
import 'art_tile.dart';
import 'shelf_grid.dart';

/// One item's page, in the trailing panel: the art, the names, the
/// facts the kind keeps, and the verbs. It borrows the queue's seat —
/// the X hands the panel back.
class ItemInspector extends StatelessWidget {
  const ItemInspector({
    required this.item,
    required this.player,
    required this.onClose,
    required this.onAddToCollection,
    super.key,
  });

  final MediaItem item;
  final PlaybackController player;
  final VoidCallback onClose;
  final VoidCallback onAddToCollection;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeProvider.of(context);
    final metadata = item.metadata;

    final title = switch (metadata) {
      AudioMetadata(:final title) => title,
      VideoMetadata(:final title) => title,
      DocumentMetadata(:final title) => title,
      ImageMetadata(:final title) => title ?? '',
    };
    final kicker = switch (metadata.kind) {
      MediaKind.audio => 'SONG',
      MediaKind.video => 'VIDEO',
      MediaKind.document => 'DOCUMENT',
      MediaKind.image => 'IMAGE',
    };
    final verb = switch (metadata.kind) {
      MediaKind.audio => 'Play',
      MediaKind.video => 'Watch',
      MediaKind.document => 'Read',
      MediaKind.image => 'View',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            theme.space.x4,
            theme.space.x2,
            theme.space.x2,
            theme.space.x1,
          ),
          child: Row(
            children: [
              KickerText(kicker),
              const Spacer(),
              Tooltip(
                message: const Text('Back to the queue'),
                child: Button(
                  onPressed: onClose,
                  variant: SurfaceVariant.ghost,
                  swatch: SemanticSwatch.neutral,
                  center: const Icon(LucideIcons.x, size: 14),
                ),
              ),
            ],
          ),
        ),
        const Divider(),
        Expanded(
          child: ListView(
            padding: EdgeInsets.all(theme.space.x4),
            children: [
              Center(
                child: SizedBox(
                  width: 160,
                  child: ArtTile(
                    title,
                    kind: metadata.kind,
                    aspectRatio: metadata is DocumentMetadata ? bookAspect : 1,
                    fileId: item.fileId,
                  ),
                ),
              ),
              Spacing(SpaceStep.x3),
              Text(
                title,
                style: theme.typography.body.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (_byline() case final byline?)
                CaptionText(byline, emphasis: TextEmphasis.secondary),
              Spacing(SpaceStep.x3),
              Wrap(
                spacing: theme.space.x2,
                runSpacing: theme.space.x2,
                children: [
                  Button(
                    onPressed: () => player.open(item),
                    center: Text(verb),
                  ),
                  if (metadata is AudioMetadata)
                    Tooltip(
                      message: const Text('Add to the queue'),
                      child: Button(
                        onPressed: () => player.enqueue([
                          AudioItem(
                            id: item.id,
                            fileId: item.fileId,
                            path: item.path,
                            metadata: metadata,
                            tags: item.tags,
                          ),
                        ]),
                        variant: SurfaceVariant.soft,
                        swatch: SemanticSwatch.neutral,
                        center: const Text('Queue'),
                      ),
                    ),
                  Button(
                    onPressed: onAddToCollection,
                    variant: SurfaceVariant.soft,
                    swatch: SemanticSwatch.neutral,
                    center: const Text('Add to…'),
                  ),
                ],
              ),
              Spacing(SpaceStep.x4),
              for (final (label, value) in _facts())
                Padding(
                  padding: EdgeInsets.only(bottom: theme.space.x2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 84,
                        child: CaptionText(
                          label,
                          emphasis: TextEmphasis.tertiary,
                        ),
                      ),
                      Expanded(
                        child: Text(value, style: theme.typography.bodySmall),
                      ),
                    ],
                  ),
                ),
              Spacing(SpaceStep.x2),
              Text(
                item.path,
                style: theme.typography.caption.copyWith(
                  color: theme.palette.text.withValues(
                    alpha: theme.opacities.tertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String? _byline() => switch (item.metadata) {
    AudioMetadata(:final artist) => artist,
    VideoMetadata(:final series, :final year) =>
      series ?? (year == null ? null : '$year'),
    DocumentMetadata(:final author) => author,
    ImageMetadata(:final cameraMake, :final cameraModel) => _joinOrNull([
      cameraMake,
      cameraModel,
    ]),
  };

  static String? _joinOrNull(List<String?> parts) {
    final joined = parts.nonNulls.join(' ');
    return joined.isEmpty ? null : joined;
  }

  /// The facts the kind keeps, in reading order. Absent values stay off
  /// the page rather than standing as empty rows.
  List<(String, String)> _facts() {
    final format = item.tags
        .where((t) => t.namespace == TagNamespace.format.id)
        .firstOrNull
        ?.name
        .toUpperCase();
    final facts = switch (item.metadata) {
      AudioMetadata(
        :final album,
        :final year,
        :final duration,
        :final trackNumber,
        :final bitrateKbps,
        :final chapters,
      ) =>
        [
          if (album != null) ('Album', album),
          if (year != null) ('Year', '$year'),
          if (duration != null) ('Length', formatClock(duration)),
          if (trackNumber != null) ('Track', '$trackNumber'),
          if (bitrateKbps != null) ('Bitrate', '$bitrateKbps kbps'),
          if (chapters.isNotEmpty) ('Chapters', '${chapters.length}'),
        ],
      VideoMetadata(
        :final year,
        :final duration,
        :final width,
        :final height,
        :final videoCodec,
        :final chapters,
      ) =>
        [
          if (year != null) ('Year', '$year'),
          if (duration != null) ('Length', formatClock(duration)),
          if (width != null && height != null) ('Resolution', '$width×$height'),
          if (videoCodec != null) ('Codec', videoCodec),
          if (chapters.isNotEmpty) ('Scenes', '${chapters.length}'),
        ],
      DocumentMetadata(
        :final publisher,
        :final series,
        :final issueNumber,
        :final pageCount,
      ) =>
        [
          if (series != null) ('Series', series),
          if (issueNumber case final n?)
            ('Issue', '#${n == n.roundToDouble() ? n.toInt() : n}'),
          if (publisher != null) ('Publisher', publisher),
          if (pageCount != null) ('Pages', '$pageCount'),
        ],
      ImageMetadata(:final width, :final height, :final takenAt) => [
        if (width != null && height != null) ('Dimensions', '$width × $height'),
        if (takenAt != null)
          (
            'Taken',
            '${takenAt.year}-'
                '${takenAt.month.toString().padLeft(2, '0')}-'
                '${takenAt.day.toString().padLeft(2, '0')}',
          ),
      ],
    };
    return [...facts, if (format != null) ('Format', format)];
  }
}
