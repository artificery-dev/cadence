import 'package:cadence/main.dart';
import 'package:cadence/src/shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

void main() {
  testWidgets('the library menu is contextual and its verbs work', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await tester.pump(const Duration(milliseconds: 100));

    // Music (the deck's home, audio): Shuffle All present — and Delete
    // too, now that the deck knows how to move house.
    await rightClick(tester, find.text('Music'));
    expect(find.text('Shuffle All'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Shuffle All'));
    // Playback starts here, and the playing scrubber repaints every
    // frame — pumpAndSettle would wait forever. Drain instead.
    await drain(tester);
    expect(boot.player.shuffle, isTrue);
    expect(boot.player.playing, isTrue);
    expect(boot.player.queue, hasLength(28));
    expect(find.textContaining('Shuffled 28 songs'), findsOneWidget);
    boot.player.stop();

    // Shows: no Shuffle All, but Rename works end to end.
    await rightClick(tester, find.text('Shows'));
    expect(find.text('Shuffle All'), findsNothing);
    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      ),
      'Serials',
    );
    // The dialog's title says Rename too; the button is the later one.
    await tester.tap(
      find
          .descendant(of: find.byType(Dialog), matching: find.text('Rename'))
          .last,
    );
    await tester.pumpAndSettle();
    expect(find.text('Serials'), findsOneWidget);
    expect(find.text('Shows'), findsNothing);

    // Scan: accepted, followed — and, with no folders to walk, promptly
    // done with nothing to report.
    await rightClick(tester, find.text('Movies'));
    await tester.tap(find.text('Scan'));
    await tester.pumpAndSettle();
    await tester.pump(AppShell.scanPollInterval);
    await tester.pumpAndSettle();
    expect(find.text('Scanned Movies: 0 added, 0 updated.'), findsOneWidget);

    // Delete: Images goes, after the confirm.
    await rightClick(tester, find.text('Images'));
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(Dialog), matching: find.text('Delete')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Images'), findsNothing);

    // Deleting the deck's home: the queue is let go, and with no other
    // audio shelf to move to, the deck sits empty but the app stands.
    await rightClick(tester, find.text('Music'));
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(Dialog), matching: find.text('Delete')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Music'), findsNothing);
    expect(boot.player.queue, isEmpty);
    expect(boot.player.playing, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
