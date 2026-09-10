import 'package:cadence/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

/// The grips, and only the sidebar's: the queue panel's rows wear the same
/// glyph, and its list is a scroll view of its own — the sidebar's sections
/// are the only thing grouped along one axis.
Finder get grips => find.descendant(
  of: find.byType(SliverMainAxisGroup),
  matching: find.byIcon(const Icons().drag),
);

void main() {
  testWidgets('each section menu holds its verbs, its lock, and its badges', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // The badges say what they are to a screen reader, not only in red.
    // Put down by hand: the binding checks for live handles before the
    // teardowns run.
    final semantics = tester.ensureSemantics();

    final boot = await testBoot();
    addTearDown(boot.client.close);
    addTearDown(boot.player.dispose);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await tester.pump(const Duration(milliseconds: 100));

    // Nothing on the headings but the dots: the + has moved inside.
    expect(find.byIcon(LucideIcons.plus), findsNothing);

    await openSectionMenu(tester, 'Libraries');
    expect(find.text('New Library…'), findsOneWidget);
    expect(find.text('Rearrange Libraries'), findsOneWidget);
    // Shut, so the padlock is closed and no tick stands beside it.
    expect(find.byIcon(LucideIcons.lock), findsOneWidget);
    expect(find.byIcon(LucideIcons.lockOpen), findsNothing);
    // Everything drawn but not wired says so, in red, three times over —
    // Scan All Libraries has since earned its keep.
    expect(find.bySemanticsLabel('Not yet implemented'), findsNWidgets(3));
    expect(find.byIcon(LucideIcons.ban), findsNWidgets(3));
    expect(find.text('Sort Libraries…'), findsOneWidget);

    // Choosing one owns up rather than doing nothing at all.
    await tester.tap(find.text('Sort Libraries…'));
    await tester.pumpAndSettle();
    expect(find.text('Sort Libraries is not yet implemented.'), findsOneWidget);

    // The Collections menu is the same shape with its own verbs.
    await openSectionMenu(tester, 'Collections');
    expect(find.text('New Collection…'), findsOneWidget);
    expect(find.text('Rearrange Collections'), findsOneWidget);
    expect(find.text('New Smart Collection…'), findsOneWidget);
    // By the label, not the glyph: the toast still standing wears one too.
    expect(find.bySemanticsLabel('Not yet implemented'), findsNWidgets(4));

    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the lock unlocks dragging, and the new order is remembered', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    addTearDown(boot.player.dispose);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await tester.pump(const Duration(milliseconds: 100));

    // Locked: the rows are rows, and there is nothing to take hold of.
    expect(grips, findsNothing);
    final seeded = [for (final row in boot.collections) row.id];
    expect(seeded, hasLength(3));

    await openSectionMenu(tester, 'Collections');
    await tester.tap(find.text('Rearrange Collections'));
    await tester.pumpAndSettle();

    // Unlocked: one grip per collection, and the padlock has opened.
    expect(grips, findsNWidgets(3));
    await openSectionMenu(tester, 'Collections');
    expect(find.byIcon(LucideIcons.lockOpen), findsOneWidget);
    expect(find.byIcon(const Icons().confirm), findsOneWidget);
    await tester.tapAt(const Offset(700, 450));
    await tester.pumpAndSettle();

    // Drag the first collection past the second.
    expect(
      tester.getTopLeft(find.text('Road Trip')).dy,
      lessThan(tester.getTopLeft(find.text('Late Night Static')).dy),
    );
    final reach =
        tester.getCenter(grips.at(1)).dy - tester.getCenter(grips.first).dy;
    final drag = await tester.startGesture(tester.getCenter(grips.first));
    await tester.pump(const Duration(milliseconds: 100));
    for (var step = 0; step < 8; step++) {
      await drag.moveBy(Offset(0, (reach + 8) / 8));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await drag.up();
    await tester.pumpAndSettle();

    // The sidebar shows the new run, and the settings remember it.
    expect(
      tester.getTopLeft(find.text('Late Night Static')).dy,
      lessThan(tester.getTopLeft(find.text('Road Trip')).dy),
    );
    // The first two swapped; the mixed canon holds the rear.
    expect(
      boot.settings.collectionOrder,
      equals([seeded[1], seeded[0], seeded[2]]),
    );

    // Locking again puts the grips away and leaves the order alone.
    await openSectionMenu(tester, 'Collections');
    await tester.tap(find.text('Rearrange Collections'));
    await tester.pumpAndSettle();
    expect(grips, findsNothing);
    expect(
      tester.getTopLeft(find.text('Late Night Static')).dy,
      lessThan(tester.getTopLeft(find.text('Road Trip')).dy),
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a library keeps its views and its own menu while it drags', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    addTearDown(boot.player.dispose);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await tester.pump(const Duration(milliseconds: 100));

    await openSectionMenu(tester, 'Libraries');
    await tester.tap(find.text('Rearrange Libraries'));
    await tester.pumpAndSettle();

    // One grip per library — every shelf is one flat row now.
    expect(grips, findsNWidgets(boot.allLibraries.length));

    // Collections stayed locked — the sections lock apart.
    expect(find.text('Road Trip'), findsOneWidget);
    await openSectionMenu(tester, 'Collections');
    expect(find.byIcon(LucideIcons.lock), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
