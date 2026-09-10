import 'dart:io';

import 'package:cadence/main.dart';
import 'package:cadence/src/shell.dart';
import 'package:cadence/src/views/collection_view.dart';
import 'package:cadence/src/views/library_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

void main() {
  testWidgets('a collection plays as laid down, and shuffle stays on '
      'the table', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    // The controller lives in Bootstrap, not the tree: its ticker must be
    // put down by hand or it outlives the test.
    addTearDown(boot.player.dispose);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await settleNav(tester);

    // Both seeded collections stand in the sidebar under their heading.
    expect(find.text('Collections'), findsOneWidget);
    expect(find.text('Road Trip'), findsOneWidget);
    expect(find.text('Late Night Static'), findsOneWidget);

    // Playing from a collection deals exactly its items, in laid order.
    await tester.tap(find.text('Road Trip'));
    await settleNav(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(CollectionView),
        matching: find.text('Mile Marker Zero'),
      ),
    );
    await settleNav(tester);
    expect(boot.player.queue, hasLength(5));
    expect(boot.player.current?.metadata.title, 'Mile Marker Zero');

    // Shuffle stays on the table, even when it doesn't make sense.
    boot.player.toggleShuffle();
    expect(boot.player.shuffle, isTrue);
    boot.player.toggleShuffle();

    // Playing straight from the library hands the deck back whole.
    await tester.tap(find.text('Music'));
    await settleNav(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(LibraryView),
        matching: find.text('Handshake'),
      ),
    );
    await settleNav(tester);
    expect(boot.player.queue, hasLength(28));

    // Put the deck down before the tree: the binding checks for stray
    // timers before teardowns run.
    boot.player.stop();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a mixed collection holds every kind and plays its audio run', (
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

    // The canon crosses the shelves: a comic, a film, and an audiobook
    // stand in one laid order, each wearing its own measure.
    await tester.tap(find.text('Broadcast Canon'));
    await settleNav(tester);
    expect(find.text('3 items'), findsOneWidget);
    expect(find.text('The Vertical Hold-Up'), findsOneWidget);
    expect(find.text('Neon Interstate: The Concert Film'), findsOneWidget);
    expect(find.text('The Carrier Tone'), findsOneWidget);
    expect(find.text('24 pp'), findsOneWidget);
    expect(find.text('96:00'), findsOneWidget);

    // The comic has no reader yet: a tap on it leaves the deck alone —
    // still holding whatever it booted with.
    final before = boot.player.current?.id;
    await tester.tap(find.text('The Vertical Hold-Up'));
    await settleNav(tester);
    expect(boot.player.current?.id, before);

    // The audiobook plays — and deals only the collection's audio run,
    // not the sitting kinds.
    await tester.tap(find.text('The Carrier Tone'));
    await settleNav(tester);
    expect(boot.player.current?.metadata.title, 'The Carrier Tone');
    expect(boot.player.queue, hasLength(1));

    boot.player.stop();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the Collections menu creates a collection', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await settleNav(tester);

    // The create action lives behind the section's dots now.
    await openSectionMenu(tester, 'Collections');
    await tester.tap(find.text('New Collection…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      ),
      'Coding Focus',
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    // The new collection stands in the sidebar and opens, empty.
    expect(find.text('Coding Focus'), findsWidgets);
    expect(find.text('Nothing here yet'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the section menus share the trailing gutter with the chevrons', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await settleNav(tester);

    // Every library is one flat row now, so the sections' dots are the
    // gutter's only tenants — and they share one centre line.
    final dots = find.byIcon(const Icons().moreVertical);
    expect(dots, findsNWidgets(2), reason: 'one set per section');
    final centres = [
      for (final button in dots.evaluate())
        tester.getCenter(find.byWidget(button.widget)).dx,
    ];
    expect(
      centres.first,
      moreOrLessEquals(centres.last, epsilon: 1),
      reason: 'one gutter, one centre line',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the Libraries menu creates a typed library', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await settleNav(tester);

    final picked = Directory.systemTemp.createTempSync('cadence_create_');
    addTearDown(() => picked.deleteSync(recursive: true));
    AppShell.pickDirectoryOverride = (_) async => picked.path;
    addTearDown(() => AppShell.pickDirectoryOverride = null);

    await openSectionMenu(tester, 'Libraries');
    await tester.tap(find.text('New Library…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      ),
      'Concert Films',
    );

    // A folder picked right here rides along with the creation.
    await tester.tap(find.text('Add Folder…'));
    await tester.pumpAndSettle();
    expect(find.text(picked.path), findsOneWidget);
    // The type select defaults to Music; choose Movies from the list.
    // Every option rides in the trigger invisibly to fix its width; only
    // the shown one takes the pointer — and the sidebar has a Music of
    // its own, so the ask stays inside the dialog.
    await tester.tap(
      find
          .descendant(of: find.byType(Dialog), matching: find.text('Music'))
          .hitTestable(),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movies').hitTestable().last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    // A single-view library: its own row, already selected, empty shelf —
    // and the picked folder already stands among its roots.
    expect(find.text('Concert Films'), findsWidgets);
    final films = (await boot.client.listLibraries()).firstWhere(
      (l) => l.name == 'Concert Films',
    );
    expect(
      (await boot.client.listRoots(films.id)).map((r) => r.path),
      contains(picked.path),
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
