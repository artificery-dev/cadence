import 'package:cadence/src/model/player.dart';
import 'package:cadence/src/views/now_playing_view.dart';
import 'package:cadence/src/widgets/art_tile.dart';
import 'package:cadence/src/widgets/lcd.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

void main() {
  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final boot = await testBoot();
    addTearDown(boot.client.close);
    await tester.pumpWidget(
      TomeApp(
        home: Scaffold(
          body: NowPlayingView(
            player: PlaybackController(List.of(boot.items)),
            settings: boot.settings,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> unmount(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox.shrink());

  testWidgets('wide: the sleeve squares itself to the deck, bottoms on the '
      'glass line', (tester) async {
    await pump(tester, const Size(1400, 900));

    final art = tester.getRect(find.byType(ArtTile));
    final lcd = tester.getRect(find.byType(LcdPanel));
    final kicker = tester.getRect(find.text('NOW PLAYING'));
    expect(art.bottom, moreOrLessEquals(lcd.bottom, epsilon: 1));
    expect(art.top, moreOrLessEquals(kicker.top, epsilon: 1));
    expect(art.width, moreOrLessEquals(art.height, epsilon: 1));

    await unmount(tester);
  });

  testWidgets('narrow: the words ride beside the sleeve and the glass keeps '
      'the full width', (tester) async {
    await pump(tester, const Size(720, 900));

    final art = tester.getRect(find.byType(ArtTile));
    final title = tester.getRect(find.text('Bloom (56k Mix)'));
    final lcd = tester.getRect(find.byType(LcdPanel));
    expect(title.left, greaterThan(art.right));
    expect(lcd.left, moreOrLessEquals(art.left, epsilon: 1));
    expect(lcd.width, greaterThan(art.width * 2));

    await unmount(tester);
  });

  testWidgets('stacked: the sleeve heads the stack, square, words '
      'left-aligned beneath', (tester) async {
    await pump(tester, const Size(430, 900));

    final art = tester.getRect(find.byType(ArtTile));
    final kicker = tester.getRect(find.text('NOW PLAYING'));
    expect(art.width, moreOrLessEquals(art.height, epsilon: 1));
    expect(kicker.top, greaterThan(art.bottom));
    expect(kicker.left, moreOrLessEquals(art.left, epsilon: 1));

    await unmount(tester);
  });

  testWidgets('stacked and shorter: the sleeve pays for the glass and the '
      'whole deck fits the screen', (tester) async {
    await pump(tester, const Size(430, 640));

    final art = tester.getRect(find.byType(ArtTile));
    expect(art.width, moreOrLessEquals(art.height, epsilon: 1));
    expect(art.width, lessThan(430 - 64), reason: 'shorter than full width');
    final lcd = tester.getRect(find.byType(LcdPanel));
    expect(lcd.bottom, lessThanOrEqualTo(640));

    await unmount(tester);
  });

  testWidgets('short: the glass bows out instead of hanging off the bottom', (
    tester,
  ) async {
    await pump(tester, const Size(1400, 420));
    expect(find.byType(LcdPanel), findsNothing);
    expect(find.text('Bloom (56k Mix)'), findsOneWidget);

    await unmount(tester);
  });
}
