// The user's shortcut overrides: `settings/keymaps/user.json`, a keymap
// merged on top of the active preset in every pane (mergeBindings: later
// wins, `-command` entries remove preset bindings). Edited by the keymap
// editor (Settings → Shortcut Editor…) and by importing a JSON file.
//
// Pure Dart (headless-testable: tool/user_keymap_test.dart). A global
// singleton with listeners: panes reload their resolver on change, the
// shell recomputes the menu shortcut labels.

import 'dart:convert';
import 'dart:io';

import '../../settings/settings_paths.dart';
import 'keymap.dart';

class UserKeymap {
  UserKeymap({String? pathOverride, this.isMac = false}) : _path = pathOverride;

  static final UserKeymap instance = UserKeymap(isMac: Platform.isMacOS);

  final String? _path;
  final bool isMac;
  String get path => _path ?? settingsPath('keymaps/user.json');

  List<KeyBinding> _bindings = const [];
  List<KeyBinding> get bindings => _bindings;

  final List<void Function()> _listeners = [];
  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);
  void _notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  /// Read the file (missing / broken = no overrides).
  Future<void> load() async {
    var loaded = const <KeyBinding>[];
    try {
      final f = File(path);
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map) {
          loaded = Keymap.fromJson(
            j.cast<String, Object?>(),
            isMac: isMac,
          ).bindings;
        }
      }
    } catch (_) {
      loaded = const [];
    }
    _bindings = loaded;
    _notify();
  }

  Future<void> save() async {
    final f = File(path);
    await f.parent.create(recursive: true);
    const enc = JsonEncoder.withIndent('  ');
    await f.writeAsString(
      enc.convert({
        'name': 'user',
        'bindings': [for (final b in _bindings) b.toJson()],
      }),
    );
  }

  /// Replace everything (import).
  Future<void> replaceAll(List<KeyBinding> bindings) async {
    _bindings = List.of(bindings);
    await save();
    _notify();
  }

  Future<void> clear() => replaceAll(const []);

  /// Add a binding (dropping an identical one first).
  Future<void> add(KeyBinding b) async {
    _bindings = [
      for (final x in _bindings)
        if (!x.sameAs(b)) x,
      b,
    ];
    await save();
    _notify();
  }

  /// Remove one of OUR entries (a user binding or a removal marker).
  Future<void> remove(KeyBinding b) async {
    _bindings = [
      for (final x in _bindings)
        if (!x.sameAs(b)) x,
    ];
    await save();
    _notify();
  }

  /// Hide a PRESET binding: record a `-command` removal for it.
  Future<void> addRemoval(KeyBinding preset) => add(
    KeyBinding(
      chords: preset.chords,
      command: '-${preset.command}',
      mode: preset.mode,
    ),
  );

  /// Drop every user entry (additions and removals) about [command]/[args].
  Future<void> resetCommand(String command, Map<String, Object?>? args) async {
    _bindings = [
      for (final x in _bindings)
        if (!(x.targetCommand == command && x.argsEqual(args))) x,
    ];
    await save();
    _notify();
  }

  /// Whether [b] (from the effective list) is one of our additions.
  bool owns(KeyBinding b) => _bindings.any((x) => !x.isRemoval && x.sameAs(b));
}

/// Effective bindings for [command]/[args] (in priority order, last wins).
List<KeyBinding> bindingsFor(
  List<KeyBinding> effective,
  String command,
  Map<String, Object?>? args,
) => [
  for (final b in effective)
    if (!b.isRemoval && b.command == command && b.argsEqual(args)) b,
];

/// Bindings that would fire for [chordKey] in [mode] (null = any mode).
List<KeyBinding> conflictsFor(
  List<KeyBinding> effective,
  String chordKey,
  String? mode,
) => [
  for (final b in effective)
    if (!b.isRemoval &&
        b.chordKey == chordKey &&
        (mode == null || b.mode == null || b.mode == mode))
      b,
];
