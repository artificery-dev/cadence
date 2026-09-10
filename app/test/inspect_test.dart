import 'package:cadence/main.dart';
import 'package:cadence/src/widgets/item_inspector.dart';
import 'package:cadence/src/widgets/queue_panel.dart';
import 'package:cadence/src/widgets/item_tap.dart';
import 'package:cadence/src/widgets/transport_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

/// The pointing grammars: on desktop a single click inspects and a double
/// click sends to the deck (or the queue, when it shows); on touch a tap
/// sends and a long press inspects.
void main() {
  Future<void> doubleTap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('desktop: click inspects, double-click plays, and an open '
      'queue turns double-clicks into enqueues', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    // The override must be back before the binding checks invariants,
    // even when an expectation trips mid-test.
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    addTearDown(boot.player.dispose);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await settleNav(tester);

    await tester.tap(find.text('Books'));
    await settleNav(tester);

    // A single click opens the item's page in the side panel — the deck
    // does not stir.
    final before = boot.player.current?.id;
    await tester.tap(find.text('read by Ada Winters'));
    // The single click speaks only after the double-click window shuts.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byType(ItemInspector), findsOneWidget);
    expect(find.text('Ada Winters'), findsOneWidget);
    expect(find.text('581:00'), findsOneWidget);
    expect(boot.player.current?.id, before);
    expect(boot.player.playing, isFalse);

    // The inspected spine wears the selection wash on the shelf.
    expect(find.byKey(ItemTap.washKey), findsOneWidget);

    // The panel is tabbed now: the Queue tab flips back without letting
    // the inspection go — the wash stays on the shelf. (First in tree:
    // the strip stands above the page, whose enqueue verb shares the
    // word.)
    await tester.tap(find.text('Queue').first);
    await tester.pumpAndSettle();
    expect(find.byType(ItemInspector), findsNothing);
    expect(find.byType(QueuePanel), findsOneWidget);
    expect(find.byKey(ItemTap.washKey), findsOneWidget);

    // With the Queue tab fronting, a double click on audio joins the
    // queue quietly: the run grows, the needle stays put.
    final queued = boot.player.queue.length;
    final current = boot.player.current?.id;
    await doubleTap(tester, find.text('read by Ada Winters'));
    expect(boot.player.queue.length, queued + 1);
    expect(boot.player.queue.last.metadata.title, 'The Carrier Tone');
    expect(boot.player.current?.id, current);

    // The Info tab still holds the page it held.
    await tester.tap(find.text('Info'));
    await tester.pumpAndSettle();
    expect(find.byType(ItemInspector), findsOneWidget);
    expect(find.text('Ada Winters'), findsOneWidget);

    // With Info fronting, a double click on the document sends it to
    // the deck — the queue is not the tab showing.
    await doubleTap(
      tester,
      find.descendant(
        of: find.byType(GridView),
        matching: find.text('Velvet Modem'),
      ),
    );
    expect(boot.player.opened, isNotNull);
    expect(boot.player.pageCount, 12);

    // The X lets the inspection go: the strip stands on (it always
    // does now), the queue fronts, and the wash leaves the shelf.
    await tester.tap(find.byIcon(LucideIcons.x));
    await tester.pumpAndSettle();
    expect(find.byType(ItemInspector), findsNothing);
    expect(find.text('Info'), findsOneWidget);
    expect(find.byType(QueuePanel), findsOneWidget);
    expect(find.byKey(ItemTap.washKey), findsNothing);

    // The now-playing well asks for the queue by name: with Info
    // fronting it fronts the Queue tab, and only when the queue is
    // already the tab showing does the same tap put the panel away.
    await tester.tap(find.text('read by Ada Winters'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byType(ItemInspector), findsOneWidget);
    // The deck still holds the opened document, so that is the name the
    // well wears.
    final well = find.descendant(
      of: find.byType(TransportBar),
      matching: find.text('Static Bloom — Liner Notes'),
    );
    await tester.tap(well);
    await tester.pumpAndSettle();
    expect(find.byType(ItemInspector), findsNothing);
    expect(find.byType(QueuePanel).hitTestable(), findsOneWidget);
    await tester.tap(well);
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel).hitTestable(), findsNothing);

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('touch: a tap plays and a long press inspects', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    addTearDown(boot.player.dispose);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await settleNav(tester);

    await tester.tap(find.text('Books'));
    await settleNav(tester);

    // The tap sends the audiobook straight to the deck.
    await tester.tap(find.text('read by Ada Winters'));
    await settleNav(tester);
    expect(boot.player.current?.metadata.title, 'The Carrier Tone');
    // Put the needle down — a running deck repaints every frame, and
    // the settles below want stillness.
    boot.player.toggle();
    await settleNav(tester);

    // The long press opens its page instead.
    await tester.longPress(
      find.descendant(
        of: find.byType(GridView),
        matching: find.text('Velvet Modem'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ItemInspector), findsOneWidget);
    expect(find.text('DOCUMENT'), findsOneWidget);

    boot.player.stop();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
