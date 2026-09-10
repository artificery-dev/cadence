import 'package:cadence/main.dart';
import 'package:cadence/src/data/bootstrap.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

void main() {
  testWidgets('the app reopens where you left it, at your level', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    addTearDown(boot.player.dispose);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await settleNav(tester);

    // Walk to Comics, set the level somewhere deliberate, and let the
    // debounce write it down.
    await tester.tap(find.text('Comics'));
    await settleNav(tester);
    boot.player.volume = 0.31;
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    // A second boot over the same shelves: the level holds and the
    // sidebar points where it pointed.
    final reborn = await Bootstrap.load(boot.connection);
    addTearDown(reborn.player.dispose);
    expect(reborn.player.volume, closeTo(0.31, 0.001));

    await tester.pumpWidget(CadenceApp(boot: reborn));
    await settleNav(tester);
    // The comics landing: its facet strip stands, the longbox shows.
    expect(find.text('Issues'), findsOneWidget);
    expect(find.text('Tales from the Test Card #1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
