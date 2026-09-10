import 'package:tomeui/tomeui.dart';
import 'package:tomeui_desktop/tomeui_desktop.dart';

import 'src/data/app_preferences.dart';
import 'src/data/background_daemon.dart';
import 'src/data/bootstrap.dart';
import 'src/data/environment.dart';
import 'src/data/hosting.dart';
import 'src/model/media_kit_engine.dart';
import 'src/model/settings.dart';
import 'src/shell.dart';

Future<void> main(List<String> args) async {
  // Tome talks to a NoWindow until a real shell is installed; without this
  // claimWindow() is a no-op and the native title bar stays.
  installWindowShell();
  await TitleBar.claimWindow();
  MediaKitEngine.ensureInitialized();
  final environment = AppEnvironment.fromArgs(args);
  await environment.prepare();
  // The library lives behind a transport: the daemon's, when the user
  // asked Cadence to run in the background and it answers; a host of our
  // own in an isolate otherwise. Either way the database is the one the
  // user service would open, so the two can hand it over.
  final preferences = await AppPreferences.load(environment.preferencesFile);
  final hosting = await HostingController.connect(
    environment: environment,
    preferences: preferences,
    daemon: BackgroundDaemon(environment: environment),
  );
  final boot = await Bootstrap.load(
    hosting.connection,
    environment: environment,
    engine: MediaKitEngine(),
    hosting: hosting,
  );
  runApp(CadenceApp(boot: boot));
}

class CadenceApp extends StatefulWidget {
  const CadenceApp({required this.boot, super.key});

  final Bootstrap boot;

  @override
  State<CadenceApp> createState() => _CadenceAppState();
}

class _CadenceAppState extends State<CadenceApp> with WidgetsBindingObserver {
  SettingsModel get _settings => widget.boot.settings;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// On the system preference, the theme is the OS's to change.
  @override
  void didChangePlatformBrightness() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) => TomeApp(
        theme: _settings.theme,
        title: 'Cadence',
        debugShowCheckedModeBanner: false,
        home: Toaster(child: AppShell(boot: widget.boot)),
      ),
    );
  }
}
