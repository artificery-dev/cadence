import 'dart:async';

import 'package:cadence/main.dart';
import 'package:cadence/src/data/bootstrap.dart';
import 'package:cadence/src/shell.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

/// A scanner with the file system taken out: it reports a few files seen,
/// waits at the [gate] for the test's say-so, lands one real film in the
/// scanned library, and finishes — enough truth for the shell's polling to
/// chew on. Ungated, it simply counts one file in and returns.
class _StagedScanner extends LibraryScanner {
  _StagedScanner(super.db);

  /// Set to hold a scan mid-flight; complete it to let the scan finish.
  Completer<void>? gate;

  @override
  Future<ScanProgress> scan(
    int libraryId, {
    ScanProgress? progress,
    bool Function()? shouldCancel,
    void Function(ScanState stage)? onStage,
    Set<String>? onlyDirs,
  }) async {
    final out = progress ?? ScanProgress();
    onStage?.call(ScanState.extracting);
    final gate = this.gate;
    if (gate == null) {
      out.seen += 1;
      out.added += 1;
      return out;
    }
    out.seen += 3;
    await gate.future;
    await LibraryRepository(db).addItem(
      libraryId: libraryId,
      path: '/videos/fresh_arrival.mp4',
      sizeBytes: 1 << 20,
      modifiedAt: DateTime.utc(2003, 6, 1),
      metadata: const VideoMetadata(
        title: 'Fresh Arrival',
        year: 2003,
        duration: Duration(minutes: 88),
      ),
      tags: [Tag.ofFormat('mp4')],
    );
    out.added += 1;
    return out;
  }
}

Future<(Bootstrap, _StagedScanner)> _bootWithScanner() async {
  late _StagedScanner scanner;
  final boot = await testBoot(
    service: (db) {
      scanner = _StagedScanner(db);
      return MediaService(
        db,
        coordinator: ScanCoordinator(db, scanner: scanner),
      );
    },
  );
  return (boot, scanner);
}

void main() {
  setUp(() {
    AppShell.scanPollInterval = const Duration(seconds: 5);
  });
  tearDown(() {
    AppShell.scanPollInterval = const Duration(milliseconds: 800);
  });

  testWidgets('a scan is followed to done and the shelf refreshes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final (boot, scanner) = await _bootWithScanner();
    addTearDown(boot.client.close);
    addTearDown(boot.player.dispose);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await tester.pump(const Duration(milliseconds: 100));

    // The shelf before: seeded films only, no arrival.
    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();
    expect(find.text('Fresh Arrival'), findsNothing);

    scanner.gate = Completer<void>();
    await rightClick(tester, find.text('Movies'));
    await tester.tap(find.text('Scan'));
    await tester.pumpAndSettle();
    expect(find.text('Scanning Movies…'), findsOneWidget);

    // The first poll reads the live counters into the same toast.
    await tester.pump(AppShell.scanPollInterval);
    await tester.pump();
    expect(find.text('Scanning Movies… 3 seen, 0 added'), findsOneWidget);

    // Let it finish: the next poll lands the tally, and the reload puts
    // the new film on the shelf.
    scanner.gate!.complete();
    await tester.pump();
    await tester.pump(AppShell.scanPollInterval);
    await tester.pumpAndSettle();
    expect(find.text('Scanned Movies: 1 added, 0 updated.'), findsOneWidget);
    expect(find.text('Fresh Arrival'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Scan All Libraries drains the queue and tallies up', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final (boot, _) = await _bootWithScanner();
    addTearDown(boot.client.close);
    addTearDown(boot.player.dispose);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await tester.pump(const Duration(milliseconds: 100));

    await openSectionMenu(tester, 'Libraries');
    await tester.tap(find.text('Scan All Libraries'));
    await tester.pumpAndSettle();

    // One poll per library walks the whole queue in order.
    final libraries = boot.allLibraries.length;
    for (var i = 0; i < libraries; i++) {
      await tester.pump(AppShell.scanPollInterval);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(
      find.text('Scanned $libraries libraries: $libraries added, 0 updated.'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
