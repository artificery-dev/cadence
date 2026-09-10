import 'package:cadence/src/data/bootstrap.dart';
import 'package:cadence/src/data/environment.dart';
import 'package:cadence/src/data/library_connection.dart';
import 'package:cadence_media/cadence_media.dart'
    hide File, Directory, FileSystemEntity, FileSystem, Link;
import 'package:file/local.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'seed.dart';

/// A whole app's worth of state over an in-memory database, furnished
/// with the mock shelf the app itself no longer seeds — the service
/// reached through the direct transport, so the same envelopes flow
/// without an isolate in the way. [service] swaps in a differently wired
/// service over the same database — a gated scanner, say; [environment]
/// boots the app portable; [seed] false boots the empty world.
Future<Bootstrap> testBoot({
  MediaService Function(MediaDatabase db)? service,
  AppEnvironment environment = const AppEnvironment.installed(),
  bool seed = true,
}) async {
  // Every test opens its own in-memory database on its own executor; the
  // multiple-databases warning guards shared executors, not this.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final db = MediaDatabase(NativeDatabase.memory());
  final client = directClient(db, service: service);
  if (seed) await seedIfEmpty(client);
  return Bootstrap.load(
    LibraryConnection.fixed(client),
    environment: environment,
  );
}

/// The service in-process behind a [MediaClient], every envelope handled
/// inside the media filesystem's zone — the real one, since scan tests
/// point roots at temp directories. [service] chooses the wiring; left
/// out, a plain service is built. [transport] wraps the call, for tests
/// that want to cut the line.
MediaClient directClient(
  MediaDatabase db, {
  MediaService Function(MediaDatabase db)? service,
  Future<Map<String, Object?>> Function(
    Future<Map<String, Object?>> Function() send,
  )?
  transport,
}) {
  const fs = LocalFileSystem();
  final served = withMediaFileSystem(
    fs,
    () => service?.call(db) ?? MediaService(db, watch: const QuietWatch()),
  );
  Future<Map<String, Object?>> send(Map<String, Object?> request) =>
      withMediaFileSystem(
        fs,
        () async =>
            (await served.handle(ServiceRequest.fromMap(request))).toMap(),
      );
  return MediaClient(
    transport == null ? send : (request) => transport(() => send(request)),
    onClose: () => withMediaFileSystem(fs, served.close),
  );
}

/// Opens a sidebar section's overflow menu. The sections stand in one
/// order — Libraries above Collections — so the dots do too.
Future<void> openSectionMenu(WidgetTester tester, String section) async {
  final dots = find.byIcon(const Icons().moreVertical);
  await tester.tap(section == 'Libraries' ? dots.first : dots.last);
  await tester.pumpAndSettle();
}

/// Opens a context menu the way a mouse does.
Future<void> rightClick(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(
    tester.getCenter(finder),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

/// pumpAndSettle for moments when the deck is playing: the scrubber
/// repaints every frame then, so "no scheduled frames" never comes and
/// pumpAndSettle waits forever. This steps through enough discrete
/// frames for menus, toasts, and routes to finish their business.
Future<void> drain(WidgetTester tester, [int frames = 8]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Two beats after a navigation: one frame for the pushed route to
/// build, and one past the transition so what left is truly gone.
Future<void> settleNav(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 320));
}

/// A watcher that watches nothing: the settings round-trip has something
/// to switch on and off, and no directory is ever really observed.
class QuietWatch implements LibraryWatchService {
  const QuietWatch();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> refresh() async {}
}
