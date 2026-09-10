import 'package:cadence/main.dart';
import 'package:cadence/src/widgets/art_tile.dart';
import 'package:cadence/src/views/albums_view.dart';
import 'package:cadence/src/views/artists_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

void main() {
  testWidgets('the albums and artists facets flip between grid and table', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await tester.pump(const Duration(milliseconds: 100));

    // Over to the crate: sleeves by default, and the toggle stands ready.
    await tester.tap(find.text('Albums'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(GridView), findsOneWidget);

    // Flip to the table: a shouted header over one row per record.
    await tester.tap(find.byIcon(LucideIcons.rows3));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(GridView), findsNothing);
    expect(find.text('ALBUM'), findsOneWidget);
    expect(find.text('YEAR'), findsOneWidget);
    // Sleeves ride the rows by default, and the rows stand taller for
    // them — but only a bit.
    final artTiles = find.descendant(
      of: find.byType(AlbumsView),
      matching: find.byType(ArtTile),
    );
    expect(artTiles, findsNWidgets(6));
    expect(tester.getSize(artTiles.first).height, 32);
    Finder inAlbums(String text) =>
        find.descendant(of: find.byType(AlbumsView), matching: find.text(text));
    for (final title in [
      'Static Bloom',
      'Neon Interstate',
      'Basement Frequencies',
      'Glass Arcade',
      'Analog Heart',
      'Last Transmission',
    ]) {
      expect(inAlbums(title), findsOneWidget, reason: title);
    }

    // The shelf's own order leads with Static Bloom; a tap on YEAR
    // reorders, and 1996's Analog Heart rises to the first row.
    double topOf(Finder finder) => tester.getTopLeft(finder).dy;
    expect(
      topOf(inAlbums('Static Bloom')),
      lessThan(topOf(inAlbums('Analog Heart'))),
    );
    await tester.tap(find.text('YEAR'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      topOf(inAlbums('Analog Heart')),
      lessThan(topOf(inAlbums('Static Bloom'))),
    );

    // The header's own button opens the column picker; unticking a
    // column clears its header from the table.
    await tester.tap(find.byIcon(LucideIcons.columns3));
    await tester.pumpAndSettle();
    expect(find.text('Year'), findsOneWidget);
    await tester.tap(find.text('Year'));
    await tester.pumpAndSettle();
    expect(find.text('YEAR'), findsNothing);
    // Tick it back on and close the menu.
    await tester.tap(find.byIcon(LucideIcons.columns3));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Year'));
    await tester.pumpAndSettle();
    expect(find.text('YEAR'), findsOneWidget);

    // And back to the sleeves.
    await tester.tap(find.byIcon(LucideIcons.layoutGrid));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(GridView), findsOneWidget);
    expect(find.text('ALBUM'), findsNothing);

    // The roster does the same trick: art tiles by default, then rows
    // with the counts spelled into columns.
    await tester.tap(find.text('Artists'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('ARTIST'), findsNothing);
    await tester.tap(find.byIcon(LucideIcons.rows3));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('ARTIST'), findsOneWidget);
    expect(find.text('ALBUMS'), findsOneWidget);
    expect(find.text('SONGS'), findsOneWidget);
    final inArtists = find.descendant(
      of: find.byType(ArtistsView),
      matching: find.text('1'),
    );
    // Every seeded artist keeps exactly one album, so six count cells.
    expect(inArtists, findsNWidgets(6));
    // Velvet Modem's catalogue, added up: 23 minutes 52 seconds.
    expect(find.text('23:52'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
