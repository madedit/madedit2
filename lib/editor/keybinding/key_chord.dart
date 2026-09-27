import 'dart:io';

/// One "chord": a set of modifiers plus a base key.
///
/// Base-key normalization rules:
///   - Letters are always lower-case; an upper-case letter (e.g. `G`) is
///     treated as `shift` + lower-case.
///   - Named keys are lower-case: escape / enter / space / tab / backspace /
///     delete / up / down / left / right / home / end / pageup / pagedown /
///     f1..f12.
///   - Digits and symbols (`:` `/` `$` …) are used verbatim as the base key.
class KeyChord {
  KeyChord(this.mods, this.key) {
    canonical = _canon();
  }

  final Set<String> mods; // 'ctrl' / 'alt' / 'shift' / 'meta'
  final String key;
  late final String canonical;

  String _canon() {
    final m = mods.toList()..sort();
    return m.isEmpty ? key : '${m.join('+')}+$key';
  }

  @override
  bool operator ==(Object other) =>
      other is KeyChord && other.canonical == canonical;

  @override
  int get hashCode => canonical.hashCode;

  @override
  String toString() => canonical;
}

/// Parses a binding string into a chord sequence. Chords are separated by
/// whitespace, modifiers are joined with `+`:
///   "ctrl+k ctrl+s"  → [ctrl+k, ctrl+s]
///   "g g"            → [g, g]
///   "G"              → [shift+g]
List<KeyChord> parseChords(String spec, {bool isMac = false}) {
  return spec
      .trim()
      .split(RegExp(r'\s+'))
      .where((c) => c.isNotEmpty)
      .map((c) => parseChord(c, isMac: isMac))
      .toList();
}

KeyChord parseChord(String spec, {bool isMac = false}) {
  final parts = spec.split('+');
  final mods = <String>{};
  // The last segment is the base key; the rest are modifiers (handles the
  // edge case of a trailing '+' meaning the "+" key)
  var keyRaw = parts.isEmpty ? '' : parts.last;
  if (keyRaw.isEmpty && parts.length >= 2) keyRaw = '+'; // e.g. "ctrl++"
  for (var i = 0; i < parts.length - 1; i++) {
    final p = parts[i].toLowerCase();
    if (p.isEmpty) continue;
    mods.add(_normMod(p, isMac));
  }

  var key = keyRaw;
  if (key.length == 1 && RegExp(r'[A-Z]').hasMatch(key)) {
    mods.add('shift');
    key = key.toLowerCase();
  } else {
    key = key.toLowerCase();
  }
  return KeyChord(mods, key);
}

/// Human label of a chord: "Ctrl+Shift+S", "Alt+Up", "F3", "Ctrl+/" — or,
/// on macOS ([mac]), the keyboard glyphs in Apple's order: "⇧⌘S", "⌥↑".
String chordLabel(KeyChord c, {bool? mac}) {
  final isMac = mac ?? Platform.isMacOS;
  if (isMac) {
    const order = ['ctrl', 'alt', 'shift', 'meta']; // ⌃ ⌥ ⇧ ⌘
    const glyph = {'ctrl': '⌃', 'alt': '⌥', 'shift': '⇧', 'meta': '⌘'};
    const keyGlyph = {
      'escape': '⎋',
      'enter': '↩',
      'space': '␣',
      'tab': '⇥',
      'backspace': '⌫',
      'delete': '⌦',
      'up': '↑',
      'down': '↓',
      'left': '←',
      'right': '→',
      'home': '↖',
      'end': '↘',
      'pageup': '⇞',
      'pagedown': '⇟',
    };
    final sb = StringBuffer();
    for (final m in order) {
      if (c.mods.contains(m)) sb.write(glyph[m]);
    }
    sb.write(keyGlyph[c.key] ?? c.key.toUpperCase());
    return sb.toString();
  }
  const order = ['ctrl', 'alt', 'shift', 'meta'];
  const modNames = {
    'ctrl': 'Ctrl',
    'alt': 'Alt',
    'shift': 'Shift',
    'meta': 'Win',
  };
  const keyNames = {
    'escape': 'Esc',
    'enter': 'Enter',
    'space': 'Space',
    'tab': 'Tab',
    'backspace': 'Backspace',
    'delete': 'Delete',
    'up': 'Up',
    'down': 'Down',
    'left': 'Left',
    'right': 'Right',
    'home': 'Home',
    'end': 'End',
    'pageup': 'PageUp',
    'pagedown': 'PageDown',
  };
  final parts = [
    for (final m in order)
      if (c.mods.contains(m)) modNames[m]!,
  ];
  parts.add(keyNames[c.key] ?? c.key.toUpperCase());
  return parts.join('+');
}

/// Label of a chord sequence ("Ctrl+K Ctrl+S" / "⌘K ⌘S").
String chordsLabel(List<KeyChord> chords, {bool? mac}) =>
    chords.map((c) => chordLabel(c, mac: mac)).join(' ');

// Modifier names in a keymap file:
//   ctrl    = the platform's primary shortcut modifier → ⌘ on macOS, Ctrl elsewhere
//             (so one preset serves every platform: ctrl+s is ⌘S on a Mac)
//   control = the physical Control key on every platform (vim's ctrl+d etc.)
//   alt/option, shift, meta/cmd/super/win, and mod (= ctrl above, kept for
//   older files).
String _normMod(String m, bool isMac) {
  switch (m) {
    case 'ctrl':
      return isMac ? 'meta' : 'ctrl';
    case 'control':
      return 'ctrl';
    case 'alt':
    case 'option':
    case 'opt':
      return 'alt';
    case 'shift':
      return 'shift';
    case 'cmd':
    case 'command':
    case 'meta':
    case 'super':
    case 'win':
      return 'meta';
    case 'mod': // cross-platform alias: mac → meta (⌘), everywhere else → ctrl
      return isMac ? 'meta' : 'ctrl';
  }
  return m;
}
