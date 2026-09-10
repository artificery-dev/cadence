import 'dart:convert';

import 'package:cadence/src/data/artwork_cache.dart';
import 'package:cadence/src/data/library_connection.dart';
import 'package:cadence/src/widgets/art_tile.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

/// A real 1×1 PNG, so the Image widget has something it can decode.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
  'AAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  testWidgets('the tile wears the real cover when the cache has one', (
    tester,
  ) async {
    // A service of one picture: file 1 answers with the PNG, everyone
    // else sits bare.
    final client = MediaClient((request) async {
      final path = request['path'] as String;
      final id = request['id'] as int;
      if (path == '/files/1/artwork') {
        return {
          'id': id,
          'status': 200,
          'body': {
            'role': 'thumbnail',
            'mime': 'image/png',
            'bytesBase64': base64Encode(_png),
          },
        };
      }
      return {'id': id, 'status': 404, 'body': <String, Object?>{}};
    });
    final cache = ArtworkCache(LibraryConnection.fixed(client));
    addTearDown(cache.dispose);

    await tester.pumpWidget(
      TomeApp(
        home: ArtworkScope(
          cache: cache,
          child: const Row(
            children: [
              ArtTile('Static Bloom', size: 48, fileId: 1),
              ArtTile('Neon Interstate', size: 48, fileId: 2),
              ArtTile('No file behind me', size: 48),
            ],
          ),
        ),
      ),
    );

    // First frame: everyone wears the placeholder while the asks fly.
    expect(find.byType(Image), findsNothing);

    await tester.pump();
    await tester.pump();

    // The cover landed on the first tile; the bare file and the
    // file-less tile keep their stand-ins.
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(DecoratedBox), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
