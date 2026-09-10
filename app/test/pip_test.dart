import 'package:cadence/main.dart';
import 'package:cadence/src/shell.dart';
import 'package:cadence/src/widgets/video_surface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

void main() {
  testWidgets('a film takes the stage; leaving it folds into the corner', (
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

    // Starting a film walks straight to Now Playing: the stage, the
    // names beneath it, no pip anywhere.
    await tester.tap(find.text('Movies'));
    await settleNav(tester);
    await tester.tap(find.text('Neon Interstate: The Concert Film'));
    await settleNav(tester);
    await settleNav(tester);
    expect(find.byKey(PipWindow.pipKey), findsNothing);
    // The stage is the body, wall to wall — no card around the picture.
    final stage = tester.getSize(find.byType(DeckVideoSurface));
    expect(stage.width, greaterThan(700));
    expect(stage.height, greaterThan(500));

    // Still the film for the settles below.
    boot.player.toggle();
    await settleNav(tester);

    // Leaving the stage leaves the picture behind, folded into the
    // corner of the next view.
    await tester.tap(find.text('Music'));
    await settleNav(tester);
    expect(find.byKey(PipWindow.pipKey), findsOneWidget);
    expect(find.byType(DeckVideoSurface), findsOneWidget);

    // A tap on the pip walks back to the stage, and the pip goes.
    await tester.tap(find.byKey(PipWindow.pipKey));
    await settleNav(tester);
    expect(find.byKey(PipWindow.pipKey), findsNothing);
    expect(
      tester.getSize(find.byType(DeckVideoSurface)).width,
      greaterThan(700),
    );

    boot.player.stop();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fullscreen hands the picture the whole window', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final windowCalls = <bool>[];
    AppShell.setFullScreenOverride = (fullscreen) async =>
        windowCalls.add(fullscreen);
    addTearDown(() => AppShell.setFullScreenOverride = null);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    addTearDown(boot.player.dispose);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await settleNav(tester);

    await tester.tap(find.text('Movies'));
    await settleNav(tester);
    await tester.tap(find.text('Neon Interstate: The Concert Film'));
    await settleNav(tester);
    await settleNav(tester);
    boot.player.toggle();
    await settleNav(tester);

    // The watching face carries the fullscreen seat; taking it drops
    // the chrome — no sidebar, just the picture and the deck.
    await tester.tap(find.byIcon(LucideIcons.maximize));
    await settleNav(tester);
    expect(windowCalls, [true]);
    expect(find.text('Music'), findsNothing);
    expect(find.byType(DeckVideoSurface), findsOneWidget);

    // The same seat hands the window back.
    await tester.tap(find.byIcon(LucideIcons.minimize));
    await settleNav(tester);
    expect(windowCalls, [true, false]);
    expect(find.text('Music'), findsOneWidget);

    boot.player.stop();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
