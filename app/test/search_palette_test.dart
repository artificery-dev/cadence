import 'package:cadence/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

void main() {
  testWidgets('the sidebar Search opens the palette, not a page', (
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

    // The page body carries no search box any more.
    expect(find.text('Search your library'), findsNothing);
    expect(find.text('Carrier Tone'), findsWidgets);

    // The sidebar row opens the palette over the page…
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Search everything…'), findsOneWidget);

    // …and closing it lands back where we were: the songs, untouched.
    await tester.tap(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byIcon(const Icons().close),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Carrier Tone'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
