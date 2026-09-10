import 'package:cadence/main.dart';
import 'package:cadence/src/widgets/art_tile.dart';
import 'package:cadence/src/widgets/detail_header.dart';
import 'package:cadence_media/cadence_media.dart' hide Link;
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

void main() {
  testWidgets('sleeves, names, and covers open their pages; back walks out', (
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

    // Albums facet: tapping a sleeve opens the record's page.
    await tester.tap(find.text('Albums'));
    await settleNav(tester);

    // The sleeve wears a hero tag on the grid…
    bool albumHero(Widget w) => w is Hero && w.tag == 'album-Static Bloom-art';
    expect(find.byWidgetPredicate(albumHero), findsOneWidget);
    await tester.tap(find.text('Static Bloom').first);
    await settleNav(tester);
    // …and the same tag on the page: the flight had both its ends.
    expect(find.byWidgetPredicate(albumHero), findsOneWidget);
    expect(find.text('ALBUM'), findsOneWidget);
    expect(find.text('Carrier Tone'), findsWidgets);
    expect(find.text('Play'), findsOneWidget);

    // The record opens in running order: track one above track three.
    expect(
      tester.getTopLeft(find.text('Carrier Tone').last).dy,
      lessThan(tester.getTopLeft(find.text('Handshake').last).dy),
    );

    // Scrolling the tracks folds the header: the sleeve shrinks. (The
    // folded bar keeps a small tile of its own, so the big one is second
    // in tree order.)
    final sleeve = find.byType(ArtTile).at(1);
    final tall = tester.getSize(sleeve).height;
    await tester.drag(find.byType(ListView).last, const Offset(0, -400));
    await tester.pump();
    expect(tester.getSize(sleeve).height, lessThan(tall));
    await tester.drag(find.byType(ListView).last, const Offset(0, 400));
    await tester.pump();

    // The page's verbs: Shuffle deals the record with the toggle lit…
    await tester.tap(find.text('Shuffle'));
    await settleNav(tester);
    expect(boot.player.shuffle, isTrue);
    expect(boot.player.queue, hasLength(5));
    boot.player.stop();

    // …Queue appends without touching what plays…
    final before = boot.player.queue.length;
    // The trailing panel's tab strip shares the word; only the album
    // page's verb takes the pointer while the panel is closed.
    await tester.tap(find.text('Queue').hitTestable());
    await settleNav(tester);
    expect(boot.player.queue.length, before);

    // …and Add to… offers the collections, appending once each.
    await tester.tap(find.text('Add to…'));
    await tester.pumpAndSettle();
    expect(find.text('Road Trip'), findsWidgets);
    await tester.tap(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text('Road Trip'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('to Road Trip'), findsOneWidget);
    final roadTrip = (await boot.client.listCollections()).firstWhere(
      (c) => c.name == 'Road Trip',
    );
    final entries = await boot.client.collectionEntries(roadTrip.id);
    // The programme held five and gains the album's tracks not already
    // aboard; nothing lands twice.
    expect(entries.toSet().length, entries.length);
    expect(entries.length, greaterThan(5));

    // The artist link walks deeper; the artist page shows their shelf.
    await tester.tap(find.widgetWithText(Link, 'Velvet Modem'));
    await settleNav(tester);
    expect(find.text('ARTIST'), findsOneWidget);
    expect(find.text('ALBUMS'), findsOneWidget);
    expect(find.text('SONGS'), findsOneWidget);

    // Back retraces the walk: artist page, album page, then the crate.
    await tester.tap(find.byIcon(LucideIcons.arrowLeft));
    await settleNav(tester);
    expect(find.text('ALBUM'), findsOneWidget);
    await tester.tap(find.byIcon(LucideIcons.arrowLeft));
    await settleNav(tester);
    expect(find.text('ALBUM'), findsNothing);
    expect(find.text('Albums'), findsOneWidget);

    // A show's cover opens the run: its episodes, in order.
    await tester.tap(find.text('Shows'));
    await settleNav(tester);
    await tester.tap(find.text('Test Pattern After Dark'));
    await settleNav(tester);
    expect(find.text('SERIES'), findsOneWidget);
    expect(find.text('S1E1'), findsOneWidget);
    expect(find.text('The Sign-On Ceremony'), findsOneWidget);

    // Choosing a sidebar destination clears the whole walk.
    await tester.tap(find.text('Comics'));
    await settleNav(tester);
    expect(find.text('SERIES'), findsNothing);

    // A comic run's cover opens its issues.
    await tester.tap(find.text('Series'));
    await settleNav(tester);
    await tester.tap(find.text('Tales from the Test Card'));
    await settleNav(tester);
    expect(find.text('SERIES'), findsOneWidget);
    expect(find.text('2 issues'), findsOneWidget);
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('The Vertical Hold-Up'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the folded bar: Play holds the corner, the ellipsis at '
      'its left, and the fine print yields before the name', (tester) async {
    tester.view.physicalSize = const Size(430, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final header = DetailHeader(
      onBack: () {},
      art: 'seed',
      artKind: MediaKind.audio,
      title: 'A Name Too Long To Yield An Inch',
      actions: [
        DetailAction(
          icon: LucideIcons.play,
          label: 'Play',
          onPressed: () {},
          primary: true,
        ),
        DetailAction(
          icon: LucideIcons.shuffle,
          label: 'Shuffle',
          onPressed: () {},
        ),
        DetailAction(
          icon: LucideIcons.listPlus,
          label: 'Queue',
          onPressed: () {},
        ),
        DetailAction(
          icon: LucideIcons.list,
          label: 'Add to…',
          onPressed: () {},
        ),
      ],
    );
    await tester.pumpWidget(
      TomeApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: CollapsingDetailHeader(
                  header: header,
                  details: const ['Velvet Modem', '2003', '12 songs · 47:00'],
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 2000)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    // Fold the head all the way down.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pump();

    // The fine print yielded to the long name — every word of it.
    expect(find.text('12 songs · 47:00'), findsNothing);
    expect(find.text('2003'), findsNothing);
    // The name stands, given its full measure before anything else —
    // once on the folded line, once in the fading block beneath.
    expect(find.text('A Name Too Long To Yield An Inch'), findsNWidgets(2));

    // Play holds the very corner; the ellipsis stands at its left; the
    // lesser verbs wait behind it. The folded line's copies are the ones
    // nearest the top — the fading block beneath keeps its own.
    Offset topmost(Finder finder) => finder
        .evaluate()
        .map((e) {
          final box = e.renderObject! as RenderBox;
          return box.localToGlobal(box.size.center(Offset.zero));
        })
        .reduce((a, b) => a.dy <= b.dy ? a : b);
    final play = topmost(find.byIcon(LucideIcons.play));
    final dots = topmost(find.byIcon(LucideIcons.ellipsis));
    expect(play.dy, dots.dy, reason: 'both on the folded line');
    expect(play.dx, greaterThan(dots.dx));
    expect(find.byIcon(LucideIcons.shuffle).hitTestable(), findsNothing);
    await tester.tapAt(dots);
    await tester.pumpAndSettle();
    expect(find.text('Shuffle'), findsOneWidget);
    expect(find.text('Queue'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('crowded headers fold their verbs into the ellipsis', (
    tester,
  ) async {
    // Narrow enough that four labelled verbs cannot all stand.
    tester.view.physicalSize = const Size(760, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    addTearDown(boot.player.dispose);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await settleNav(tester);

    await tester.tap(find.text('Albums'));
    await settleNav(tester);
    await tester.tap(find.text('Static Bloom').first);
    await settleNav(tester);

    // Play stands; the tail waits behind the ellipsis, whole.
    expect(find.text('Play'), findsOneWidget);
    // The folded bar keeps an (inert) ellipsis of its own; the live one
    // is the full head's.
    expect(find.byIcon(LucideIcons.ellipsis).hitTestable(), findsOneWidget);
    await tester.tap(find.byIcon(LucideIcons.ellipsis).hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Add to…'), findsOneWidget);
    await tester.tap(find.text('Add to…'));
    await tester.pumpAndSettle();
    expect(find.text('Add to collection'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
