import 'dart:async';
import 'dart:io';
import 'dart:ui' show FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';

import 'editor/highlight.dart';
import 'editor/outline.dart';
import 'editor/large_file_view.dart';
import 'editor/user_script.dart';
import 'editor/wasm_grammar.dart';
import 'l10n/app_localizations.dart';
import 'settings/app_settings.dart';
import 'settings/config_loader.dart';
import 'src/rust/frb_generated.dart';
import 'util/log.dart';
import 'util/mac_files.dart';
import 'util/single_instance.dart';

Future<void> main(List<String> args) async {
  Log.instance.mark('main entered');
  WidgetsFlutterBinding.ensureInitialized();
  Log.instance.mark('Flutter binding initialized');

  // Everything else on the command line is a file to open (shell "open with"
  // / file association); flag-style args are not ours and are skipped —
  // except --new-window (ctrl+shift+n spawns a second process with it).
  final newWindow = args.contains('--new-window');
  final cliPaths = <String>[
    for (final a in args)
      if (!a.startsWith('-')) a,
  ];
  for (final a in args) {
    if (a.startsWith('-') && a != '--new-window') {
      Log.instance.w('command line: unknown flag ignored: $a');
    }
  }

  // Single instance: when another instance is already running, hand the file
  // paths over to it (it opens them and comes to the foreground) and exit —
  // before any heavy init (Rust DLL, settings, window). A --new-window
  // process deliberately stays outside the guard: the primary keeps the
  // lock, and this window neither restores nor persists the session.
  singleInstanceLog = (String m, {bool warn = false}) =>
      warn ? Log.instance.w(m) : Log.instance.i(m);
  if (!newWindow && await SingleInstance.claim(settingsDir, cliPaths) == null) {
    exit(0);
  }

  Log.instance.mark('single-instance claimed');
  await windowManager.ensureInitialized();
  Log.instance.mark('window_manager initialized');

  // User settings (settings/settings.json): fonts / colours / thresholds /
  // startup preferences all come from here, and it must load first so we
  // know whether the log goes to a file and which UI language to use.
  // app_settings deliberately does not depend on Log (that would make it
  // untestable headless), so its log hook is wired up here.
  settingsLog = (String m, {bool warn = false}) =>
      warn ? Log.instance.w(m) : Log.instance.i(m);
  MacFiles.log = (String m, {bool warn = false}) =>
      warn ? Log.instance.w(m) : Log.instance.i(m);
  await AppSettings.instance.load();
  Log.instance.mark('settings loaded');

  // Log: console only by default; when enabled in settings, also written to settings/logs/.
  await Log.instance.init(
    fileDir: AppSettings.instance.logToFile
        ? '$settingsDir${Platform.pathSeparator}logs'
        : null,
  );
  // Settings were loaded before the log file was opened (logToFile had to be
  // known first), so record this line again so the log file sees it too.
  Log.instance.i('settings in use: ${AppSettings.filePath}');
  Log.instance.mark('log file opened');

  // Initialize flutter_rust_bridge (the Rust/tree-sitter backend for syntax highlighting).
  // A failure here (stale DLL picked up from the working directory → content
  // hash mismatch, missing library) must not abort main(): the single-instance
  // lock is already claimed and the window not yet shown, so an aborted main
  // left an invisible process that answered every later launch's handshake
  // with "ok" — the app looked dead until that process was killed. Run
  // without the native backends instead (pure-Dart highlighting, no scripts).
  try {
    await RustLib.init();
    Log.instance.mark('Rust library initialized');
  } catch (e, st) {
    nativeBackendAvailable = false;
    Log.instance.w(
      'Rust library failed to initialize — tree-sitter highlighting and '
      'user scripts are disabled for this run: $e\n$st',
    );
  }

  // Load the installed WASM grammar plugins: only enumerate languages and
  // extensions (the wasm itself is read on first use), and do not await it --
  // it runs in parallel with the first frame; _loadDocument awaits
  // registry.ready when opening a file.
  if (nativeBackendAvailable) {
    WasmGrammarRegistry.instance.load().then(
      (_) => Log.instance.mark('WASM grammars listed (parallel)'),
    );
  }

  // Lexer config of the pure-Dart fallback highlighter (user-editable
  // settings/highlight.json; bundled assets/highlight.json as default).
  // Both are layered over the bundled copy per language, so a new version's
  // languages and rules reach users whose settings/ copy was seeded long ago
  // (it is never overwritten) while their own edits keep winning.
  try {
    HighlightConfig.instance = HighlightConfig.fromJson(
      await loadConfigJsonMerged(
        'highlight.json',
        listById: const {'languages': 'name'},
        mapKeys: const {'default'},
      ),
    );
  } catch (e) {
    Log.instance.w('highlight.json load failed, using bare lexer defaults: $e');
  }
  // Document outline rules (user-editable settings/outline.json).
  try {
    OutlineConfig.instance = OutlineConfig.fromJson(
      await loadConfigJsonMerged(
        'outline.json',
        mapKeys: const {'languages'},
      ),
    );
  } catch (e) {
    Log.instance.w('outline.json load failed, outline disabled: $e');
  }

  Log.instance.mark('highlight/outline config loaded');
  // UI languages = the .arb files present (bundled + settings/l10n/): the
  // language menu and locale resolution are built from this list.
  await AppLocalizations.discover();
  await Log.instance.flush(); // make sure the startup-load log lines hit disk

  // Restore the window geometry saved in the last session (settings.json's
  // `session.window`); first run keeps the platform default size.
  final s = AppSettings.instance;
  await windowManager.waitUntilReadyToShow(null, () async {
    // A --new-window process skips the saved geometry (it would sit exactly
    // on top of the primary window) and takes the platform default.
    if (!newWindow && s.winW != null && s.winH != null) {
      await windowManager.setBounds(
        Rect.fromLTWH(s.winX ?? 100, s.winY ?? 100, s.winW!, s.winH!),
      );
    }
    if (!newWindow && s.winMaximized) await windowManager.maximize();
    await windowManager.show();
    await windowManager.focus();
  });

  Log.instance.mark('window shown, runApp');
  runApp(MyApp(initialPaths: cliPaths, sessionEnabled: !newWindow));

  // Work the first frame does not need, run once it is on screen. Every
  // loader falls back to the bundled copy while settings/ is still unseeded,
  // so nothing above depends on the seeding; the scripts registry only feeds
  // the Tools menu and script commands — the shell rebuilds its menu when
  // deferredStartup completes (the submenu's items are built with the shell,
  // not on expand).
  final deferred = Completer<void>();
  deferredStartup = deferred.future;
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      // First run copies the default config files into the settings/ directory
      // next to the executable so users can edit them externally.
      await seedConfigFiles();
      Log.instance.mark('config files seeded (deferred)');
      // Load user scripts (settings/scripts/*.js, Tools menu; plugin).
      if (nativeBackendAvailable) {
        await UserScriptRegistry.instance.load(); // compiles via the Rust engines
        Log.instance.mark('user scripts loaded (deferred)');
      }
    } finally {
      deferred.complete();
    }
  });
}

class MyApp extends StatefulWidget {
  const MyApp({
    super.key,
    this.initialPaths = const [],
    this.sessionEnabled = true,
  });

  /// File paths from the command line, handed down to the editor shell.
  final List<String> initialPaths;

  /// False for a --new-window process: it neither restores nor persists the
  /// session (two processes would clobber each other's settings.json).
  final bool sessionEnabled;

  /// Switches the app language from anywhere in the subtree (used by the
  /// menubar's "Language" menu); null = follow the system. The language is
  /// stored in settings (settings.json `startup.locale`), so the choice is
  /// remembered.
  static void setLocale(BuildContext context, Locale? locale) {
    final s = AppSettings.instance;
    final draft = AppSettings.from(s)..locale = _localeTag(locale);
    s.adopt(draft); // notifies listeners (including _MyAppState) and writes settings.json
  }

  @override
  State<MyApp> createState() => _MyAppState();
}

/// Locale ↔ settings string ('' = follow the system); the list comes from AppLocalizations.discover.
String _localeTag(Locale? l) => l == null ? '' : AppLocalizations.tagOf(l);

Locale? _localeOf(String tag) => AppLocalizations.localeFor(tag);

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  // Diagnostic: a frame that took far longer than it should, split into the
  // UI-thread part (build/layout/paint) and the raster-thread part (GPU,
  // glyph rasterization). Tells which side a stall — e.g. after a font
  // change — is on, since UI-side steps have their own "slow:" timers.
  void _onFrameTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final build = t.buildDuration.inMilliseconds;
      final raster = t.rasterDuration.inMilliseconds;
      if (build >= 500 || raster >= 500) {
        Log.instance.w(
          'slow frame: build $build ms, raster $raster ms '
          '(total ${t.totalSpan.inMilliseconds} ms)',
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addTimingsCallback(_onFrameTimings);
    AppSettings.instance.addListener(_onSettingsChanged);
    // The "follow system" colour mode needs to know whether the platform is
    // currently dark or light; the settings model does not touch dart:ui, so
    // it is fed from here. During init assign directly (no listeners exist
    // yet, so no notification is needed or wanted).
    AppSettings.instance.systemIsDark = _platformIsDark;
    WidgetsBinding.instance.addObserver(this);
  }

  bool get _platformIsDark =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
      Brightness.dark;

  @override
  void didChangePlatformBrightness() {
    AppSettings.instance.setSystemBrightness(isDark: _platformIsDark);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.removeTimingsCallback(_onFrameTimings);
    AppSettings.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) setState(() {}); // language etc. changed → rebuild the MaterialApp
  }

  @override
  Widget build(BuildContext context) {
    final locale = _localeOf(AppSettings.instance.locale); // null = follow the system
    final app = MaterialApp(
      title: 'madedit2',
      // Colour mode (Settings → Appearance): the app's own menus/dialogs go
      // dark/light along with it.
      theme: ThemeData(
        useMaterial3: true,
        brightness: AppSettings.instance.isDark
            ? Brightness.dark
            : Brightness.light,
        // UI scale (Settings → Appearance): icons via the theme (AppBar/menus read it
        // from here), text via the MediaQuery scaler in `builder` below.
        iconTheme: IconThemeData(size: 24 * AppSettings.instance.uiScale),
        // Menus (menubar, dynamic submenus, context menus built from
        // MenuItemButton): tighter rows than Material's default 48px.
        menuButtonTheme: MenuButtonThemeData(
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 12, vertical: 0),
            ),
            minimumSize: WidgetStatePropertyAll(
              Size(0, AppSettings.instance.menuRowHeight),
            ),
            fixedSize: WidgetStatePropertyAll(
              Size.fromHeight(AppSettings.instance.menuRowHeight),
            ),
            iconSize: WidgetStatePropertyAll(18 * AppSettings.instance.uiScale),
          ),
        ),
        popupMenuTheme: const PopupMenuThemeData(
          menuPadding: EdgeInsets.symmetric(vertical: 4),
        ),
        menuTheme: const MenuThemeData(
          style: MenuStyle(
            padding: WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
          ),
        ),
      ),
      // UI text scale: everything the app draws with Text widgets (menus,
      // tabs, dialogs, status bar). The editor paints its own paragraphs at
      // the editor font size, so it is deliberately unaffected.
      builder: (context, child) {
        final s = AppSettings.instance.uiScale;
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(s)),
          child: IconTheme.merge(
            data: IconThemeData(size: 24 * s),
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
      // Localization: menubar text goes through AppLocalizations (ARB runtime
      // dictionary); the other three delegates localize the built-in
      // Material/Cupertino widgets. locale=null follows the system.
      locale: locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: LargeFileEditorPage(
        initialPaths: widget.initialPaths,
        sessionEnabled: widget.sessionEnabled,
      ),
    );
    // Known Flutter Windows engine bug: dialog/menu teardown sends AXTree
    // updates referencing removed nodes, spamming "Failed to update
    // ui::AXTree" errors. No app-side fix exists — suppress by not emitting
    // a semantics tree at all. Tradeoff: screen readers see nothing; drop
    // this once the engine fix ships.
    return Platform.isWindows ? ExcludeSemantics(child: app) : app;
  }
}
