import 'package:cadence/main.dart';
import 'package:cadence/src/widgets/lcd.dart';
import 'package:cadence/src/widgets/transport_bar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

void main() {
  testWidgets('the shell renders and every view survives a visit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await settleNav(tester);

    // Songs: the table is up with the library in it. (Titles can also
    // appear in the queue panel, which lives in the tree even shut.)
    expect(find.text('Carrier Tone'), findsWidgets);

    // Albums: the crate.
    await tester.tap(find.text('Albums'));
    await settleNav(tester);
    expect(find.text('Neon Interstate'), findsOneWidget);

    // Now Playing: the deck, with its LCD flair. Clicking the glass walks
    // the visualizer modes.
    await tester.tap(find.text('Now Playing'));
    await settleNav(tester);
    expect(find.text('STEREO'), findsOneWidget);
    expect(find.text('SPECTRUM'), findsOneWidget);
    await tester.tap(find.byType(Visualizer));
    await settleNav(tester);
    expect(find.text('SCOPE'), findsOneWidget);

    // Settings: the cards.
    await tester.tap(find.text('Settings'));
    await settleNav(tester);
    expect(find.text('Appearance'), findsOneWidget);

    // The mini track card opens the queue sidebar.
    await tester.tap(
      find.descendant(
        of: find.byType(TransportBar),
        matching: find.text('Bloom (56k Mix)'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('QUEUE'), findsOneWidget);

    // Unmount so the spectrum's ticker and the player's clock wind down.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
