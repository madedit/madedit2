// Keyboard macros: record the editor's keyboard-driven actions and replay
// them (Macro menu). Pure Dart, headless-testable (tool/macro_test.dart).
//
// A macro is a list of steps — a named editor command (what the keymap
// resolved, or a menu item that maps to one), a committed text insertion
// (what the IME delivered), or one of the control keys the editor handles
// outside the keymap (backspace / delete / tab / shift+tab). Mouse actions
// are not recorded. Macros persist as JSON in settings/macros/<name>.json.

import 'dart:convert';
import 'dart:io';

import '../settings/settings_paths.dart';

sealed class MacroStep {
  const MacroStep();

  Map<String, Object?> toJson();

  static MacroStep? fromJson(Map<String, Object?> j) {
    switch (j['type']) {
      case 'command':
        final name = j['name'];
        if (name is! String || name.isEmpty) return null;
        final args = j['args'];
        final count = j['count'];
        return MacroCommand(
          name,
          args: args is Map ? args.cast<String, Object?>() : null,
          count: count is int && count > 0 ? count : 1,
        );
      case 'insert':
        final text = j['text'];
        return text is String && text.isNotEmpty ? MacroInsert(text) : null;
      case 'key':
        final key = j['key'];
        return key is String && MacroKey.keys.contains(key)
            ? MacroKey(key)
            : null;
    }
    return null;
  }
}

/// A keymap command by name (with the keymap's args and repeat count).
final class MacroCommand extends MacroStep {
  const MacroCommand(this.name, {this.args, this.count = 1});
  final String name;
  final Map<String, Object?>? args;
  final int count;

  @override
  Map<String, Object?> toJson() => {
    'type': 'command',
    'name': name,
    if (args != null) 'args': args,
    if (count != 1) 'count': count,
  };
}

/// Text committed through the IME (typing, Enter as "\n").
final class MacroInsert extends MacroStep {
  const MacroInsert(this.text);
  final String text;

  @override
  Map<String, Object?> toJson() => {'type': 'insert', 'text': text};
}

/// One of the control keys the editor handles outside the keymap.
final class MacroKey extends MacroStep {
  const MacroKey(this.key);
  final String key;

  static const keys = {'backspace', 'delete', 'tab', 'shiftTab'};

  @override
  Map<String, Object?> toJson() => {'type': 'key', 'key': key};
}

class Macro {
  const Macro(this.name, this.steps);
  final String name;
  final List<MacroStep> steps;

  Map<String, Object?> toJson() => {
    'name': name,
    'steps': [for (final s in steps) s.toJson()],
  };

  /// Parses leniently: unknown/broken steps are dropped, never fatal.
  static Macro fromJson(Map<String, Object?> j, {String? fallbackName}) {
    final name = j['name'];
    final raw = j['steps'];
    final steps = <MacroStep>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          final s = MacroStep.fromJson(e.cast<String, Object?>());
          if (s != null) steps.add(s);
        }
      }
    }
    return Macro(name is String ? name : (fallbackName ?? ''), steps);
  }
}

/// Commands that never go into a macro: the macro commands themselves
/// (recursion), undo/redo (playback groups all its edits into one undo
/// step, so an undo inside it would pop unrelated history), and the
/// command palette (it re-dispatches what it runs).
bool isRecordableCommand(String name) =>
    !name.startsWith('macro.') &&
    name != 'edit.undo' &&
    name != 'edit.redo' &&
    name != 'view.commandPalette';

/// Global recorder: the editor and the shell push steps while [recording].
class MacroRecorder {
  static final MacroRecorder instance = MacroRecorder();

  bool _recording = false;
  final List<MacroStep> _steps = [];
  final List<void Function()> _listeners = [];

  /// The most recently recorded (non-empty) macro — what "play" replays.
  Macro? last;

  bool get recording => _recording;
  int get stepCount => _steps.length;

  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);
  void _notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void start() {
    _steps.clear();
    _recording = true;
    _notify();
  }

  /// Stops and returns what was recorded (null when nothing was). A
  /// non-empty recording becomes [last].
  Macro? stop() {
    if (!_recording) return null;
    _recording = false;
    final m = _steps.isEmpty ? null : Macro('', List.of(_steps));
    if (m != null) last = m;
    _notify();
    return m;
  }

  /// Append a step (ignored when not recording or not recordable).
  /// Consecutive insertions merge so typing a word is one step.
  void add(MacroStep s) {
    if (!_recording) return;
    if (s is MacroCommand && !isRecordableCommand(s.name)) return;
    if (s is MacroInsert && _steps.isNotEmpty && _steps.last is MacroInsert) {
      final prev = _steps.last as MacroInsert;
      _steps[_steps.length - 1] = MacroInsert(prev.text + s.text);
    } else {
      _steps.add(s);
    }
    _notify();
  }
}

/// `settings/macros/<name>.json`.
class MacroStore {
  MacroStore([String? dir])
    : dir = dir ?? '$settingsDir${Platform.pathSeparator}macros';

  final String dir;

  static final _badChars = RegExp(r'[\\/:*?"<>|]');

  /// A usable file stem: non-empty, trimmed, no path/reserved characters.
  static bool validName(String name) =>
      name.isNotEmpty &&
      name.trim() == name &&
      name.length <= 64 &&
      !name.startsWith('.') &&
      !_badChars.hasMatch(name);

  String _path(String name) => '$dir${Platform.pathSeparator}$name.json';

  /// Saved macro names, sorted (case-insensitive).
  Future<List<String>> list() async {
    final d = Directory(dir);
    if (!await d.exists()) return const [];
    final names = <String>[];
    await for (final e in d.list(followLinks: false)) {
      if (e is! File) continue;
      final n = e.path.split(Platform.pathSeparator).last;
      if (!n.endsWith('.json') || n.startsWith('.')) continue;
      names.add(n.substring(0, n.length - 5));
    }
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return names;
  }

  Future<void> save(Macro m) async {
    if (!validName(m.name)) throw ArgumentError('bad macro name: ${m.name}');
    await Directory(dir).create(recursive: true);
    const enc = JsonEncoder.withIndent('  ');
    await File(_path(m.name)).writeAsString(enc.convert(m.toJson()));
  }

  /// null when missing or unreadable.
  Future<Macro?> load(String name) async {
    if (!validName(name)) return null;
    try {
      final raw = await File(_path(name)).readAsString();
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      return Macro.fromJson(j.cast<String, Object?>(), fallbackName: name);
    } catch (_) {
      return null;
    }
  }

  Future<void> delete(String name) async {
    if (!validName(name)) return;
    final f = File(_path(name));
    if (await f.exists()) await f.delete();
  }
}
