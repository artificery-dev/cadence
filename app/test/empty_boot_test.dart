import 'package:cadence/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

void main() {
  testWidgets('an unseeded world boots empty and stands', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot(seed: false);
    addTearDown(boot.client.close);
    addTearDown(boot.player.dispose);
    expect(boot.library, isNull);
    expect(boot.items, isEmpty);
    expect(boot.collections, isEmpty);

    await tester.pumpWidget(CadenceApp(boot: boot));
    await tester.pump(const Duration(milliseconds: 100));

    // Nothing to show but the shell itself — and it shows.
    expect(tester.takeException(), isNull);
    expect(find.text('Now Playing'), findsOneWidget);
    expect(find.text('Libraries'), findsOneWidget);

    // The first real library arrives the honest way: made by hand.
    await openSectionMenu(tester, 'Libraries');
    await tester.tap(find.text('New Library…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      ),
      'Records',
    );
    await tester.tap(
      find.descendant(of: find.byType(Dialog), matching: find.text('Create')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Records'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
