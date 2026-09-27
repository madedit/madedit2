import 'key_chord.dart';
import 'when_expr.dart';

/// One key binding.
class KeyBinding {
  KeyBinding({
    required this.chords,
    required this.command,
    this.args,
    this.mode,
    this.when,
    this.whenExpr,
  });

  final List<KeyChord> chords;
  final String command; // a leading '-' means "remove" a preset binding
  final Map<String, Object?>? args;
  final String? mode; // null = global (active in every mode)
  final String? when;
  final WhenExpr? whenExpr;

  bool get isRemoval => command.startsWith('-');
  String get targetCommand => isRemoval ? command.substring(1) : command;

  String get chordKey => chords.map((c) => c.canonical).join(' ');

  /// Same args map (order-insensitive; null and {} are equal).
  bool argsEqual(Map<String, Object?>? other) {
    final a = args ?? const {}, b = other ?? const {};
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (!b.containsKey(e.key) || b[e.key] != e.value) return false;
    }
    return true;
  }

  /// Same binding as far as a keymap file is concerned.
  bool sameAs(KeyBinding o) =>
      chordKey == o.chordKey &&
      command == o.command &&
      mode == o.mode &&
      argsEqual(o.args);

  Map<String, Object?> toJson() => {
    'keys': chordKey,
    'command': command,
    if (args != null && args!.isNotEmpty) 'args': args,
    if (mode != null) 'mode': mode,
    if (when != null && when!.trim().isNotEmpty) 'when': when,
  };

  static KeyBinding fromJson(Map<String, Object?> j, {bool isMac = false}) {
    final keys = (j['keys'] ?? j['key']) as String? ?? '';
    final when = j['when'] as String?;
    return KeyBinding(
      chords: parseChords(keys, isMac: isMac),
      command: j['command'] as String? ?? 'noop',
      args: (j['args'] as Map?)?.cast<String, Object?>(),
      mode: j['mode'] as String?,
      when: when,
      whenExpr: (when != null && when.trim().isNotEmpty)
          ? WhenExpr.parse(when)
          : null,
    );
  }
}

/// One keymap (preset).
class Keymap {
  Keymap({
    required this.name,
    required this.defaultMode,
    required this.bindings,
  });

  final String name;
  final String? defaultMode; // null = non-modal (e.g. vscode); 'normal' = modal (vim)
  final List<KeyBinding> bindings;

  /// Parses from a JSON map (does not handle `extends`; the loader flattens
  /// `extends` before calling this).
  static Keymap fromJson(Map<String, Object?> j, {bool isMac = false}) {
    final list = (j['bindings'] as List? ?? const [])
        .map(
          (e) => KeyBinding.fromJson(
            (e as Map).cast<String, Object?>(),
            isMac: isMac,
          ),
        )
        .toList();
    return Keymap(
      name: j['name'] as String? ?? 'unnamed',
      defaultMode: j['defaultMode'] as String?,
      bindings: list,
    );
  }
}

/// Loads a keymap by name and recursively flattens `extends`. [fetch] is
/// supplied by the caller (the view reads assets, tests read files) and
/// returns the JSON map for that name.
Future<Keymap> loadKeymapByName(
  String name,
  Future<Map<String, Object?>> Function(String name) fetch, {
  bool isMac = false,
}) async {
  final j = await fetch(name);
  final self = Keymap.fromJson(j, isMac: isMac);
  final ext = j['extends'] as String?;
  if (ext == null) return self;
  final base = await loadKeymapByName(ext, fetch, isMac: isMac);
  return Keymap(
    name: self.name,
    defaultMode: self.defaultMode ?? base.defaultMode,
    bindings: mergeBindings(base.bindings, self.bindings),
  );
}

/// Merges bindings: [overrides] are evaluated later and win; `-command`
/// removes the matching binding (same chord sequence + same command + same mode).
List<KeyBinding> mergeBindings(
  List<KeyBinding> base,
  List<KeyBinding> overrides,
) {
  final result = List<KeyBinding>.from(base);
  for (final ob in overrides) {
    if (ob.isRemoval) {
      result.removeWhere(
        (b) =>
            b.chordKey == ob.chordKey &&
            b.command == ob.targetCommand &&
            b.mode == ob.mode,
      );
    } else {
      result.add(ob); // added later = higher priority
    }
  }
  return result;
}

/// The binding to show as [command]'s shortcut label, or null when it has
/// none. Candidates are the global bindings plus, when [mode] is given, that
/// mode's. Ranking (highest first), so the label never depends on where a
/// binding happens to sit in the file:
///   1. a binding whose `when` names the platform — a platform pair spells
///      out the chord this platform's user actually presses (⌘↑ on macOS),
///      while the portable half is the other platform's;
///   2. a global binding over a mode-specific one — the menu shows what works
///      everywhere, not what a modal preset does in one mode (⌘Z, not vim `u`);
///   3. the last one, which is the keymap's own override order.
/// Argful bindings (`view.gotoTab {n}`) never label a plain menu item.
KeyBinding? labelBindingFor(
  List<KeyBinding> bindings,
  String command, {
  String? mode,
}) {
  KeyBinding? pick;
  var best = -1;
  for (final b in bindings) {
    if (b.isRemoval || b.command != command) continue;
    if (b.args != null && b.args!.isNotEmpty) continue;
    if (b.mode != null && b.mode != mode) continue;
    final score =
        ((b.when ?? '').contains('platform') ? 2 : 0) + (b.mode == null ? 1 : 0);
    if (score >= best) {
      best = score;
      pick = b;
    }
  }
  return pick;
}

/// Bindings that apply on [platform] ('windows' | 'macos' | 'linux'): a
/// binding whose `when` mentions `platform` is evaluated with just that
/// variable and dropped when false; every other binding is kept. Presets pair
/// bindings this way (alt+→ is "go forward" off macOS, "word right" on it),
/// so listing them unfiltered — menu shortcut labels, the keymap editor —
/// would show keys as double-bound.
List<KeyBinding> activeOnPlatform(List<KeyBinding> bindings, String platform) {
  final ctx = <String, Object?>{'platform': platform};
  return [
    for (final b in bindings)
      if (b.whenExpr == null ||
          !(b.when ?? '').contains('platform') ||
          b.whenExpr!.eval(ctx))
        b,
  ];
}
