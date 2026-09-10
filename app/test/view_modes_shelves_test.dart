import 'package:cadence/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

/// The grid/table toggle on the episodic and printed shelves: Shows,
/// Comics, and Books each flip to a sortable table and back, keeping the
/// grouped list and the cover grids as their grid faces.
void main() {
  testWidgets('shows flip to a flat episode table that sorts', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await settleNav(tester);

    await tester.tap(find.text('Shows'));
    await settleNav(tester);

    // The landing: the Series facet, one cover per run.
    expect(find.text('Test Pattern After Dark'), findsOneWidget);
    expect(find.text('The Midnight Dial Radio Hour'), findsOneWidget);
    expect(find.text('3 episodes'), findsOneWidget);
    expect(find.text('2 episodes'), findsOneWidget);

    // The Episodes facet opens flat — a header strip and one row per
    // episode, video and audio together; the grouped list waits behind
    // the grid toggle.
    await tester.tap(find.text('Episodes'));
    await settleNav(tester);
    await tester.tap(find.byIcon(LucideIcons.layoutGrid));
    await settleNav(tester);
    expect(find.text('TEST PATTERN AFTER DARK'), findsOneWidget);
    expect(find.text('S1E1 · The Sign-On Ceremony'), findsOneWidget);
    await tester.tap(find.byIcon(LucideIcons.rows3));
    await settleNav(tester);
    expect(find.text('SERIES'), findsOneWidget);
    expect(find.text('EPISODE'), findsOneWidget);
    expect(find.text('S1E2'), findsOneWidget);
    expect(find.text('E1'), findsOneWidget);
    expect(find.text('The Sign-On Ceremony'), findsOneWidget);

    // Sorting by title puts 'Adjust Your Set' above 'Vertical Hold'.
    await tester.tap(find.text('TITLE'));
    await settleNav(tester);
    expect(
      tester.getTopLeft(find.text('Adjust Your Set')).dy,
      lessThan(tester.getTopLeft(find.text('Vertical Hold')).dy),
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the longbox flips to a table and sorts by issue', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await settleNav(tester);

    await tester.tap(find.text('Comics'));
    await settleNav(tester);

    await tester.tap(find.byIcon(LucideIcons.rows3));
    await settleNav(tester);

    // Issue numbers wear the octothorpe; the page count sits bare.
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('24'), findsOneWidget);

    // Twice on ISSUE turns the sort around: issue 2 rises to the top.
    await tester.tap(find.text('ISSUE'));
    await settleNav(tester);
    await tester.tap(find.text('ISSUE'));
    await settleNav(tester);
    expect(
      tester.getTopLeft(find.text('#2')).dy,
      lessThan(tester.getTopLeft(find.text('#1')).dy),
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the book shelf flips to a table of kinds and lengths', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await settleNav(tester);

    await tester.tap(find.text('Books'));
    await settleNav(tester);

    // The landing is a grid of covers, the longbox's way: bylines under
    // the spines, no headers standing yet.
    expect(find.byType(GridView), findsOneWidget);
    expect(find.text('read by Ada Winters'), findsOneWidget);
    expect(find.text('LENGTH'), findsNothing);

    await tester.tap(find.byIcon(LucideIcons.rows3));
    await settleNav(tester);

    // The audiobook names its kind and counts its hours; the document
    // names its format, and — pageless in the seed — leaves the length
    // column empty under its header.
    expect(find.text('audiobook'), findsOneWidget);
    expect(find.text('581:00'), findsOneWidget);
    expect(find.text('PDF'), findsOneWidget);
    expect(find.text('LENGTH'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
