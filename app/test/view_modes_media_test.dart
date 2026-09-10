import 'package:cadence/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

void main() {
  testWidgets('the movies shelf turns into a sortable table and back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await settleNav(tester);

    await tester.tap(find.text('Movies'));
    await settleNav(tester);
    expect(find.text('Neon Interstate: The Concert Film'), findsOneWidget);

    // Flip to the table: the headers stand up and the films become rows.
    await tester.tap(find.byIcon(LucideIcons.rows3));
    await settleNav(tester);
    expect(find.text('TITLE'), findsOneWidget);
    expect(find.text('Neon Interstate: The Concert Film'), findsOneWidget);

    // The shelf's own order leads with Neon Interstate (2000); a tap on
    // YEAR sorts ascending, so Static Bloom (1998) climbs above it.
    double top(String title) => tester.getTopLeft(find.text(title)).dy;
    expect(
      top('Neon Interstate: The Concert Film'),
      lessThan(top('Static Bloom: Live at the Loop')),
      reason: 'the shelf order before any sort',
    );
    await tester.tap(find.text('YEAR'));
    await settleNav(tester);
    expect(
      top('Static Bloom: Live at the Loop'),
      lessThan(top('Neon Interstate: The Concert Film')),
      reason: '1998 before 2000, ascending',
    );
    await tester.tap(find.text('YEAR'));
    await settleNav(tester);
    expect(
      top('Neon Interstate: The Concert Film'),
      lessThan(top('Static Bloom: Live at the Loop')),
      reason: '2000 before 1998, descending',
    );

    // And back to the shelf: the headers sit down, the posters return.
    await tester.tap(find.byIcon(LucideIcons.layoutGrid));
    await settleNav(tester);
    expect(find.text('TITLE'), findsNothing);
    expect(find.byType(GridView), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the gallery table shows dimensions and sorts by taken', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await settleNav(tester);

    await tester.tap(find.text('Images'));
    await settleNav(tester);
    expect(find.text('Cathode Bloom'), findsOneWidget);

    await tester.tap(find.byIcon(LucideIcons.rows3));
    await settleNav(tester);
    expect(find.text('TAKEN'), findsOneWidget);
    expect(find.text('2560×1440'), findsOneWidget);

    // A tap on TAKEN orders the crate by shutter day: 1999, 2000, 2001.
    await tester.tap(find.text('TAKEN'));
    await settleNav(tester);
    double top(String title) => tester.getTopLeft(find.text(title)).dy;
    expect(top('Neon Grid Sunset'), lessThan(top('Cathode Bloom')));
    expect(top('Cathode Bloom'), lessThan(top('Overpass at 2AM')));

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
