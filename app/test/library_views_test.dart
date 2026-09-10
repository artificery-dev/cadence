import 'package:cadence/main.dart';
import 'package:cadence/src/views/library_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

void main() {
  testWidgets('every library is one row; the facets ride inside the page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await settleNav(tester);

    // The sidebar: one flat row per library, no folds, no view rows.
    for (final name in [
      'Music',
      'Podcasts',
      'Shows',
      'Movies',
      'Books',
      'Comics',
      'Images',
    ]) {
      expect(find.text(name), findsOneWidget, reason: name);
    }

    // Music opens on its songs facet; the toggle stands in the page.
    expect(find.text('Carrier Tone'), findsWidgets);
    await tester.tap(find.text('Artists'));
    await settleNav(tester);
    // Artist names also live in the (closed) queue panel's rows.
    expect(find.text('Velvet Modem'), findsWidgets);
    expect(find.text('1 albums · 5 songs'), findsWidgets);

    await tester.tap(find.text('Albums'));
    await settleNav(tester);
    expect(find.text('Static Bloom'), findsWidgets);

    // The chosen facet is remembered per library.
    await tester.tap(find.text('Movies'));
    await settleNav(tester);
    expect(find.text('Neon Interstate: The Concert Film'), findsOneWidget);
    await tester.tap(find.text('Music'));
    await settleNav(tester);
    expect(find.text('Static Bloom'), findsWidgets);

    await tester.tap(find.text('Podcasts'));
    await settleNav(tester);
    // The landing is the Series facet; Episodes stands one tap away.
    expect(find.text('The Hold Music Hour'), findsOneWidget);
    expect(find.text('3 episodes'), findsOneWidget);
    await tester.tap(find.text('Episodes'));
    await settleNav(tester);
    expect(find.text('On Hold with the Phone Company'), findsOneWidget);

    await tester.tap(find.text('Shows'));
    await settleNav(tester);
    expect(find.text('Test Pattern After Dark'), findsOneWidget);
    expect(find.text('The Midnight Dial Radio Hour'), findsOneWidget);

    await tester.tap(find.text('Books'));
    await settleNav(tester);
    // The shelf lands on covers now, the longbox's way: the audiobook
    // keeps its byline and the document credits its author.
    expect(find.text('read by Ada Winters'), findsOneWidget);
    expect(find.text('Static Bloom — Liner Notes'), findsOneWidget);

    await tester.tap(find.text('Comics'));
    await settleNav(tester);
    expect(find.text('The Vertical Hold-Up'), findsOneWidget);
    expect(find.text('Tales from the Test Card #1'), findsOneWidget);

    await tester.tap(find.text('Images'));
    await settleNav(tester);
    expect(find.text('Cathode Bloom'), findsOneWidget);
    expect(find.text('2560 × 1440'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the songs table breathes at both ends', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await settleNav(tester);

    final list = find.descendant(
      of: find.byType(LibraryView),
      matching: find.byType(ListView),
    );
    final viewport = tester.getRect(list);
    final first = tester.getRect(
      find.descendant(of: list, matching: find.text('Carrier Tone')).first,
    );
    // The row's own box, not its words: the text sits inside a 28px row.
    final row = tester.getRect(
      find
          .ancestor(
            of: find.text('Carrier Tone'),
            matching: find.byType(SizedBox),
          )
          .first,
    );
    final next = tester.getRect(
      find
          .ancestor(
            of: find.text('Dial Slow, Dream Fast'),
            matching: find.byType(SizedBox),
          )
          .first,
    );

    final gap = next.top - row.bottom;
    expect(gap, greaterThan(0), reason: 'the rows are spaced at all');
    expect(
      row.top - viewport.top,
      moreOrLessEquals(gap * 2, epsilon: 0.5),
      reason: 'twice the air above the first row as between any two',
    );
    expect(first.top, greaterThan(viewport.top));

    // The tail is past the fold, so the inset is the thing to read: at
    // the end of the run it matches the sides rather than the gap.
    final inset = tester
        .widget<ListView>(list)
        .padding!
        .resolve(TextDirection.ltr);
    expect(inset.bottom, inset.left, reason: 'the bottom matches the sides');
    expect(inset.bottom, greaterThan(inset.top));

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
