import 'package:cadence_media/cadence_media.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  testWidgets('the seed covers every library type and every media kind', (
    tester,
  ) async {
    final boot = await testBoot();
    addTearDown(boot.client.close);

    expect(
      boot.allLibraries.map((l) => l.type).toSet(),
      LibraryType.values.toSet(),
      reason: 'one library of every type',
    );

    final kinds = {
      for (final items in boot.itemsByLibrary.values)
        for (final item in items) item.metadata.kind,
    };
    expect(
      kinds,
      MediaKind.values.toSet(),
      reason: 'at least one item of every kind',
    );

    // The music library the shell fronts is untouched by the newcomers.
    expect(boot.items, hasLength(28));

    // Episodic video carries its series; the search index knows the
    // newcomers too — asked through the service like everything else.
    expect(await boot.client.search('vertical hold'), isNotEmpty);
    expect(await boot.client.search('carrier tone'), isNotEmpty);
    expect(await boot.client.search('overpass'), isNotEmpty);
  });
}
