import 'package:cadence_media/cadence_media.dart';
import 'package:cadence/src/model/player.dart';
import 'package:cadence/src/widgets/queue_panel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

void main() {
  testWidgets('shuffle and repeat live on the queue header now', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    final player = PlaybackController(List.of(boot.items));
    addTearDown(player.dispose);
    await tester.pumpWidget(
      TomeApp(
        home: SizedBox(width: 256, child: QueuePanel(player: player)),
      ),
    );
    await tester.pump();

    // Both moods stand beside the count, off at rest.
    expect(find.byIcon(LucideIcons.shuffle), findsOneWidget);
    expect(find.byIcon(LucideIcons.repeat), findsOneWidget);
    expect(find.text('28 items'), findsOneWidget);

    await tester.tap(find.byIcon(LucideIcons.shuffle));
    await tester.pump();
    expect(player.shuffle, isTrue);

    // Repeat cycles off → all → one, and the glyph follows.
    await tester.tap(find.byIcon(LucideIcons.repeat));
    await tester.pump();
    expect(player.repeat, LoopMode.all);
    await tester.tap(find.byIcon(LucideIcons.repeat));
    await tester.pump();
    expect(player.repeat, LoopMode.one);
    expect(find.byIcon(LucideIcons.repeat1), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the run follows whatever plays, not just music', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    final player = PlaybackController(List.of(boot.items));
    addTearDown(player.dispose);
    await tester.pumpWidget(
      TomeApp(
        home: SizedBox(width: 256, child: QueuePanel(player: player)),
      ),
    );
    await tester.pump();
    expect(find.text('28 items'), findsOneWidget);

    // Opening a comic replaces the run with the thing being read.
    player.open(
      const MediaItem(
        id: 900,
        fileId: 900,
        path: '/comics/issue.cbz',
        metadata: DocumentMetadata(
          title: 'The Vertical Hold-Up',
          pageCount: 24,
        ),
        tags: [],
      ),
    );
    await tester.pump();
    expect(find.text('1 item'), findsOneWidget);
    expect(find.text('The Vertical Hold-Up'), findsOneWidget);
    expect(find.text('24 pp'), findsOneWidget);
    // A run of one has nothing to rearrange: no grips.
    expect(find.byIcon(LucideIcons.gripVertical), findsNothing);

    // Audio takes the deck back, and the queue returns whole.
    player.play(boot.items.first);
    await tester.pump();
    expect(find.text('28 items'), findsOneWidget);

    player.stop();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
