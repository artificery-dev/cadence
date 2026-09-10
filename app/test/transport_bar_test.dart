import 'package:cadence_media/cadence_media.dart';
import 'package:flutter/gestures.dart';
import 'package:cadence/src/model/player.dart';
import 'package:cadence/src/widgets/transport_bar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

void main() {
  Future<PlaybackController> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final boot = await testBoot();
    addTearDown(boot.client.close);
    final player = PlaybackController(List.of(boot.items));
    addTearDown(player.dispose);
    await tester.pumpWidget(
      TomeApp(
        home: Scaffold(
          body: const SizedBox.expand(),
          statusbars: [TransportBar(player: player)],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    return player;
  }

  testWidgets('wide: one row, two rules, volume folded into its flyout', (
    tester,
  ) async {
    final player = await pump(tester, const Size(1280, 800));

    expect(find.byType(Divider), findsNWidgets(2));
    // Only the scrubber's slider is on the bar; volume waits in the popover.
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byIcon(LucideIcons.rotateCcw), findsOneWidget);
    expect(find.byIcon(LucideIcons.rotateCw), findsOneWidget);
    expect(find.byIcon(LucideIcons.micVocal), findsOneWidget);

    // The stations hold their ends: info at the start, volume at the end,
    // whatever the slack.
    final bar = tester.getRect(find.byType(TransportBar));
    expect(
      bar.right - tester.getRect(find.byIcon(LucideIcons.volume2)).right,
      lessThan(48),
    );
    expect(
      tester.getRect(find.text('Bloom (56k Mix)')).left - bar.left,
      lessThan(80),
    );

    // The clocks left the scrubber; the card counts down what remains —
    // the seeded deck sits 1:07 into Bloom's 6:11.
    expect(find.text('1:07'), findsNothing);
    expect(find.text('6:11'), findsNothing);
    expect(find.text('-5:04'), findsOneWidget);

    // The scrubber floats astride the seam: its centreline rests on the
    // band's top edge, the knob's upper half over the page above.
    final slider = tester.getRect(find.byType(Slider));
    expect(slider.center.dy, moreOrLessEquals(bar.top, epsilon: 0.5));

    // And the whole knob answers: a drag that starts in its upper half
    // still seeks.
    final before = player.progress;
    await tester.dragFrom(
      Offset(slider.center.dx, slider.top + 3),
      const Offset(-200, 0),
    );
    await tester.pump();
    expect(player.progress, isNot(moreOrLessEquals(before, epsilon: 0.001)));

    // The flyout opens on the volume button: a standing fader with the
    // mute at its foot.
    await tester.tap(find.byIcon(LucideIcons.volume2));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNWidgets(2));
    expect(tester.widget<Slider>(find.byType(Slider).last).axis, Axis.vertical);
    await tester.tap(find.byIcon(LucideIcons.volumeOff));
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.volumeX), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('wide holds together right down to the fold', (tester) async {
    // Sweep the squeeze: from one pixel above the fold up through the
    // widths that have bitten before. The spacers and the mini card's
    // words yield; nothing may clip at any of them.
    for (final width in const [661.0, 700.0, 760.0, 850.0, 1000.0]) {
      await pump(tester, Size(width, 800));
      expect(
        find.byIcon(LucideIcons.volume2),
        findsOneWidget,
        reason: 'at $width',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('compact holds together at any width worth having', (
    tester,
  ) async {
    for (final width in const [300.0, 360.0, 420.0, 500.0, 600.0, 659.0]) {
      await pump(tester, Size(width, 800));
      expect(
        find.byIcon(LucideIcons.play),
        findsOneWidget,
        reason: 'at $width',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('the glyphs speak on hover', (tester) async {
    await pump(tester, const Size(1280, 800));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    // Linger on the play button past the tooltip's wait: it speaks.
    await mouse.moveTo(tester.getCenter(find.byIcon(LucideIcons.play)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('Play'), findsOneWidget);

    // Wander off: the word goes with the pointer.
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Play'), findsNothing);

    // The lyrics button is disabled, but still explains itself.
    await mouse.moveTo(tester.getCenter(find.byIcon(LucideIcons.micVocal)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('Lyrics, someday'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('compact: the groups fold at the seams into three rows', (
    tester,
  ) async {
    await pump(tester, const Size(480, 800));

    expect(find.byType(Divider), findsNothing);
    expect(find.byType(Slider), findsOneWidget);
    // Everything still present, just wrapped — shuffle and repeat are
    // not on the bar at any width; they live on the queue's header.
    expect(find.byIcon(LucideIcons.play), findsOneWidget);
    expect(find.byIcon(LucideIcons.shuffle), findsNothing);
    expect(find.byIcon(LucideIcons.micVocal), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('scene hops and chapter hops take the outer seats', (
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
        home: Scaffold(
          body: const SizedBox.expand(),
          statusbars: [TransportBar(player: player)],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final everything = boot.itemsByLibrary.values.expand((items) => items);

    // A film that knows its set list: the watching face seats the scene
    // hops the music face keeps for its queue.
    final concert = everything.firstWhere(
      (item) => switch (item.metadata) {
        VideoMetadata(:final chapters) => chapters.isNotEmpty,
        _ => false,
      },
    );
    player.open(concert);
    player.toggle(); // still, so the settles below settle
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.skipBack), findsOneWidget);
    expect(find.byIcon(LucideIcons.skipForward), findsOneWidget);
    expect(find.byIcon(LucideIcons.captions), findsOneWidget);

    // The hop moves the needle to the next scene stop.
    await tester.tap(find.byIcon(LucideIcons.skipForward));
    await tester.pump();
    expect(player.position, const Duration(minutes: 12));

    // A film without stops keeps the three-seat face.
    final plain = everything.firstWhere(
      (item) => switch (item.metadata) {
        VideoMetadata(:final chapters) => chapters.isEmpty,
        _ => false,
      },
    );
    player.open(plain);
    player.toggle();
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.skipBack), findsNothing);
    expect(find.byIcon(LucideIcons.skipForward), findsNothing);

    // An audiobook keeps the full five seats, but the outer two speak
    // chapters now.
    final audiobook = everything.firstWhere(
      (item) => switch (item.metadata) {
        AudioMetadata(:final chapters) => chapters.isNotEmpty,
        _ => false,
      },
    );
    player.open(audiobook);
    player.toggle();
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && (w.message as Text).data == 'Next chapter',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byIcon(LucideIcons.skipForward));
    await tester.pump();
    expect(player.position, const Duration(hours: 3));

    player.stop();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the deck slides off, swaps its face, and slides back', (
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
        home: Scaffold(
          body: const SizedBox.expand(),
          statusbars: [TransportBar(player: player)],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // The listening face: the queue transport, the lyrics seat.
    expect(find.byIcon(LucideIcons.skipForward), findsOneWidget);
    expect(find.byIcon(LucideIcons.micVocal), findsOneWidget);

    // Hand the deck a comic. Mid-slide the old face still shows; after
    // both legs the reading face stands: page turns, the bookmark seat,
    // and the page count on the card.
    final issue = boot.itemsByLibrary.values
        .expand((items) => items)
        .firstWhere(
          (item) => switch (item.metadata) {
            DocumentMetadata(:final series) => series != null,
            _ => false,
          },
        );
    player.open(issue);
    await tester.pump();
    expect(find.byIcon(LucideIcons.skipForward), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.skipForward), findsNothing);
    expect(find.byIcon(LucideIcons.chevronRight), findsOneWidget);
    expect(find.byIcon(LucideIcons.bookmark), findsOneWidget);
    expect(find.text('p. 1 / 24'), findsOneWidget);

    // The page turns move the deck's needle.
    await tester.tap(find.byIcon(LucideIcons.chevronRight));
    await tester.pump();
    expect(player.page, 1);
    expect(find.text('p. 2 / 24'), findsOneWidget);
    await tester.tap(find.byIcon(LucideIcons.chevronsRight));
    await tester.pump();
    expect(find.text('p. 24 / 24'), findsOneWidget);

    // Audio takes the deck back: two more legs, the transport returns.
    player.play(boot.items.first);
    player.stop();
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.skipForward), findsOneWidget);

    player.stop();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
