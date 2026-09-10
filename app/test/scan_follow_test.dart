import 'dart:async';

import 'package:cadence/main.dart';
import 'package:cadence/src/data/bootstrap.dart';
import 'package:cadence/src/data/library_connection.dart';
import 'package:cadence/src/shell.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';
import 'seed.dart';

/// A scanner with the file system taken out: counts one file seen, waits
/// at the [gate] when one is set, and — scanning the library named by
/// [landSongIn] — actually lands a song, so a shelf has something new to
/// show. Everywhere else it just counts.
class _GatedScanner extends LibraryScanner {
  _GatedScanner(super.db);

  /// Set to hold every scan mid-flight; complete it to let them finish.
  Completer<void>? gate;

  /// When set, only this library's scans wait at the [gate]; the rest of
  /// the shelves scan straight through.
  int? gateOnly;

  /// The library id whose scan lands a real song, when any.
  int? landSongIn;

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
    out.seen += 1;
    if (gate case final gate? when gateOnly == null || gateOnly == libraryId) {
      await gate.future;
    }
    if (libraryId == landSongIn) {
      await LibraryRepository(db).addItem(
        libraryId: libraryId,
        path: '/music/fresh_cut.flac',
        sizeBytes: 1 << 20,
        modifiedAt: DateTime.utc(2004, 4, 4),
        metadata: const AudioMetadata(
          title: 'Fresh Cut',
          artist: 'The Scanners',
          album: 'Landed',
          duration: Duration(minutes: 3),
        ),
        tags: [Tag.ofFormat('flac')],
      );
      out.added += 1;
    }
    return out;
  }
}

void main() {
  setUp(() {
    AppShell.scanPollInterval = const Duration(seconds: 5);
  });
  tearDown(() {
    AppShell.scanPollInterval = const Duration(milliseconds: 800);
  });

  Future<void> sizeView(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('a scan of the music library lands its songs on the shelf', (
    tester,
  ) async {
    await sizeView(tester);
    late _GatedScanner scanner;
    final boot = await testBoot(
      service: (db) => MediaService(
        db,
        coordinator: ScanCoordinator(db, scanner: scanner = _GatedScanner(db)),
      ),
    );
    addTearDown(boot.client.close);
    addTearDown(boot.player.dispose);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await tester.pump(const Duration(milliseconds: 100));

    // The deck opens on the songs table: the seeded shelf, no arrival yet.
    expect(find.textContaining('28 songs'), findsOneWidget);

    scanner.landSongIn = boot.library!.id;
    await rightClick(tester, find.text('Music'));
    await tester.tap(find.text('Scan'));
    await tester.pumpAndSettle();
    await tester.pump(AppShell.scanPollInterval);
    await tester.pumpAndSettle();

    // The tally speaks, and the shelf itself has grown by the arrival —
    // the summary counts the list the view was actually handed.
    expect(find.text('Scanned Music: 1 added, 0 updated.'), findsOneWidget);
    expect(find.textContaining('29 songs'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pump();
    expect(find.text('Fresh Cut'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a poll that loses the service reports it, not throws', (
    tester,
  ) async {
    await sizeView(tester);
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = MediaDatabase(NativeDatabase.memory());
    // The kill switch: flip [dead] and the transport starts refusing, the
    // way a shot-down host would.
    var dead = false;
    final client = directClient(
      db,
      service: (db) => MediaService(
        db,
        coordinator: ScanCoordinator(db, scanner: _GatedScanner(db)),
      ),
      transport: (send) {
        if (dead) throw StateError('the service is gone');
        return send();
      },
    );
    await seedIfEmpty(client);
    final boot = await Bootstrap.load(LibraryConnection.fixed(client));
    addTearDown(boot.client.close);
    addTearDown(boot.player.dispose);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await tester.pump(const Duration(milliseconds: 100));

    await rightClick(tester, find.text('Movies'));
    await tester.tap(find.text('Scan'));
    await tester.pumpAndSettle();
    expect(find.text('Scanning Movies…'), findsOneWidget);

    dead = true;
    await tester.pump(AppShell.scanPollInterval);
    await tester.pumpAndSettle();

    // The narration toast is gone and the loss is spoken, not thrown.
    expect(find.text('Scanning Movies…'), findsNothing);
    expect(
      find.textContaining('Lost sight of the scan of Movies'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('tearing the shell down mid-scan lets the toast go quietly', (
    tester,
  ) async {
    await sizeView(tester);
    late _GatedScanner scanner;
    final boot = await testBoot(
      service: (db) => MediaService(
        db,
        coordinator: ScanCoordinator(db, scanner: scanner = _GatedScanner(db)),
      ),
    );
    addTearDown(boot.client.close);
    addTearDown(boot.player.dispose);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await tester.pump(const Duration(milliseconds: 100));

    scanner.gate = Completer<void>();
    await rightClick(tester, find.text('Movies'));
    await tester.tap(find.text('Scan'));
    await tester.pumpAndSettle();
    expect(find.text('Scanning Movies…'), findsOneWidget);

    // The whole tree goes while the poll is asleep; waking, it must not
    // reach for a toaster that no longer exists.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(AppShell.scanPollInterval);
    expect(tester.takeException(), isNull);

    // Let the marooned scan finish before the database goes.
    scanner.gate!.complete();
    await tester.pump();
  });

  testWidgets('scan-all lets go of a library its drain skipped', (
    tester,
  ) async {
    await sizeView(tester);
    late _GatedScanner scanner;
    final boot = await testBoot(
      service: (db) => MediaService(
        db,
        coordinator: ScanCoordinator(db, scanner: scanner = _GatedScanner(db)),
      ),
    );
    addTearDown(boot.client.close);
    addTearDown(boot.player.dispose);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await tester.pump(const Duration(milliseconds: 100));

    // A manual scan holds the last library in the queue…
    final last = boot.allLibraries.last;
    scanner.gateOnly = last.id;
    scanner.gate = Completer<void>();
    await rightClick(tester, find.text(last.name));
    await tester.tap(find.text('Scan'));
    await tester.pumpAndSettle();
    expect(find.text('Scanning ${last.name}…'), findsOneWidget);

    // …when Scan All arrives: the host takes a job for every other shelf
    // and refuses the held one — a library already scanning is left to
    // that scan — so the follow runs the others through and tallies them.
    await openSectionMenu(tester, 'Libraries');
    await tester.tap(find.text('Scan All Libraries'));
    await tester.pumpAndSettle();

    // The manual scan finishes on its own time, under its own toast.
    scanner.gate!.complete();
    await tester.pump();

    // One poll per queued library lands the tally; the held library's
    // outcome is never polled by the drain.
    final libraries = boot.allLibraries.length;
    for (var i = 0; i < libraries - 1; i++) {
      await tester.pump(AppShell.scanPollInterval);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(
      find.text('Scanned ${libraries - 1} libraries: 0 added, 0 updated.'),
      findsOneWidget,
    );
    expect(
      find.text('Scanning ${last.name} ($libraries of $libraries)…'),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('two libraries can be followed at once', (tester) async {
    await sizeView(tester);
    late _GatedScanner scanner;
    final boot = await testBoot(
      service: (db) => MediaService(
        db,
        coordinator: ScanCoordinator(db, scanner: scanner = _GatedScanner(db)),
      ),
    );
    addTearDown(boot.client.close);
    addTearDown(boot.player.dispose);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await tester.pump(const Duration(milliseconds: 100));

    scanner.gate = Completer<void>();
    await rightClick(tester, find.text('Movies'));
    await tester.tap(find.text('Scan'));
    await tester.pumpAndSettle();
    await rightClick(tester, find.text('Shows'));
    await tester.tap(find.text('Scan'));
    await tester.pumpAndSettle();

    // Two toasts, each narrating its own library.
    expect(find.text('Scanning Movies…'), findsOneWidget);
    expect(find.text('Scanning Shows…'), findsOneWidget);
    await tester.pump(AppShell.scanPollInterval);
    await tester.pump();
    expect(find.text('Scanning Movies… 1 seen, 0 added'), findsOneWidget);
    expect(find.text('Scanning Shows… 1 seen, 0 added'), findsOneWidget);

    scanner.gate!.complete();
    await tester.pump();
    await tester.pump(AppShell.scanPollInterval);
    await tester.pumpAndSettle();
    expect(find.text('Scanned Movies: 0 added, 0 updated.'), findsOneWidget);
    expect(find.text('Scanned Shows: 0 added, 0 updated.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
