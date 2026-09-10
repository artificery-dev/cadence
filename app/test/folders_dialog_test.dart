import 'dart:io';

import 'package:cadence/main.dart';
import 'package:cadence/src/shell.dart';
import 'package:cadence/src/data/environment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

void main() {
  testWidgets('the folders dialog claims and releases roots', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final dir = Directory.systemTemp.createTempSync('cadence_folders_');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, 'song.mp3')).writeAsStringSync('not really');

    // Portable, so the add row opens pointing at the portable root.
    final boot = await testBoot(
      environment: AppEnvironment.fromArgs(['--portable-dir=${dir.path}']),
    );
    addTearDown(boot.client.close);
    addTearDown(boot.player.dispose);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await tester.pump(const Duration(milliseconds: 100));

    await rightClick(tester, find.text('Music'));
    await tester.tap(find.text('Folders…'));
    await tester.pumpAndSettle();

    // An empty shelf, an empty field — the placeholder speaks alone.
    expect(find.textContaining('No folders yet'), findsOneWidget);
    final field = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(find.text('Browse…'), findsOneWidget);

    // The doorman: relative paths, absent paths, and files are all turned
    // away before the service hears a word.
    await tester.enterText(field, 'not/absolute');
    await tester.tap(find.text('Add'));
    await tester.pump();
    expect(find.text('An absolute path, please.'), findsOneWidget);

    await tester.enterText(field, p.join(dir.path, 'nowhere'));
    await tester.tap(find.text('Add'));
    await tester.pump();
    expect(find.text('Nothing lives at that path.'), findsOneWidget);

    await tester.enterText(field, p.join(dir.path, 'song.mp3'));
    await tester.tap(find.text('Add'));
    await tester.pump();
    expect(find.text('That is a file, not a folder.'), findsOneWidget);
    expect(await boot.client.listRoots(boot.library!.id), isEmpty);

    // A real directory lands as a row, and the service remembers it.
    await tester.enterText(field, dir.path);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('That is a file, not a folder.'), findsNothing);
    expect(find.text(dir.path), findsOneWidget);
    final roots = await boot.client.listRoots(boot.library!.id);
    expect(roots, hasLength(1));
    expect(roots.single.path, dir.path);

    // Claiming the same ground twice is called out, not crashed on.
    await tester.enterText(field, dir.path);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text("Already one of this library's folders."), findsOneWidget);
    expect(await boot.client.listRoots(boot.library!.id), hasLength(1));

    // Browse: the OS picker (a tame stand-in here) answers with a folder,
    // and the pick is its own confirmation — the root lands unprompted.
    final picked = Directory(p.join(dir.path, 'picked'))..createSync();
    String? sawStart;
    AppShell.pickDirectoryOverride = (startIn) async {
      sawStart = startIn;
      return picked.path;
    };
    addTearDown(() => AppShell.pickDirectoryOverride = null);
    String? revealed;
    AppShell.revealDirectoryOverride = (path) async => revealed = path;
    addTearDown(() => AppShell.revealDirectoryOverride = null);
    await tester.tap(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byIcon(const Icons().close),
      ),
    );
    await tester.pumpAndSettle();
    await rightClick(tester, find.text('Music'));
    await tester.tap(find.text('Folders…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Browse…'));
    await tester.pumpAndSettle();
    expect(sawStart, isNotEmpty);
    expect(find.text(picked.path), findsOneWidget);

    // The folder icon is a door: tapping it hands the path to the OS's
    // file explorer (a tame stand-in here).
    await tester.tap(find.byIcon(LucideIcons.folder).first);
    await tester.pump();
    expect(revealed, dir.path);
    expect(
      (await boot.client.listRoots(boot.library!.id)).map((r) => r.path),
      contains(picked.path),
    );
    await boot.client.removeRoot(
      boot.library!.id,
      (await boot.client.listRoots(
        boot.library!.id,
      )).firstWhere((r) => r.path == picked.path).id,
    );
    await tester.tap(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byIcon(const Icons().close),
      ),
    );
    await tester.pumpAndSettle();
    await rightClick(tester, find.text('Music'));
    await tester.tap(find.text('Folders…'));
    await tester.pumpAndSettle();

    // Releasing the root bares the shelf again — the trash can, in the
    // danger colours.
    await tester.tap(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byIcon(const Icons().delete),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('No folders yet'), findsOneWidget);
    expect(await boot.client.listRoots(boot.library!.id), isEmpty);

    await tester.tap(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byIcon(const Icons().close),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
