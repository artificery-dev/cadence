import 'package:cadence/main.dart';
import 'package:cadence/src/model/settings.dart';
import 'package:cadence_media/cadence_media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tomeui/tomeui.dart';

import 'harness.dart';

/// The Library card's switch — the Background card wears one too.
final watchFolders = find.byType(Switch<bool>).first;

void main() {
  testWidgets('the watch-folders toggle round-trips through the service', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final boot = await testBoot();
    addTearDown(boot.client.close);
    addTearDown(boot.player.dispose);
    await tester.pumpWidget(CadenceApp(boot: boot));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    // Off by default — watching costs, so it asks first.
    expect(find.text('Watch folders'), findsOneWidget);
    expect(boot.settings.watchFolders, isFalse);

    await tester.tap(watchFolders);
    await tester.pumpAndSettle();
    expect(boot.settings.watchFolders, isTrue);

    // The service holds the truth under the scanner's own key…
    expect(await boot.client.getSetting(ScannerSettings.watchFolders), isTrue);

    // …and a model born fresh reads the same answer back.
    final reread = SettingsModel(boot.client);
    await reread.load();
    expect(reread.watchFolders, isTrue);

    // Off again, politely, all the way through.
    await tester.tap(watchFolders);
    await tester.pumpAndSettle();
    expect(await boot.client.getSetting(ScannerSettings.watchFolders), isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
