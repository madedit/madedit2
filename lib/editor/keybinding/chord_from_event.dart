// KeyEvent → KeyChord, shared by the editor's key handler and the keymap
// editor's "press a shortcut" recorder so both agree on what a key is
// called (flutter-dependent; the pure chord model is in key_chord.dart).

import 'dart:io';

import 'package:flutter/services.dart';

import 'key_chord.dart';

/// Modifier state read from the raw (NSEvent-level) key events.
///
/// macOS delivers modifiers two ways: as separate modifier key events, and as
/// flags on every event. [HardwareKeyboard] only tracks the former, so a tool
/// that re-injects events with correct `NSEvent.modifierFlags` but no separate
/// modifier events — Karabiner-Elements does exactly this, which macOS allows
/// since each NSEvent is self-contained — leaves it permanently empty: every
/// shortcut in the app silently stops working while Chrome/TextEdit are fine
/// (flutter#178609). The deprecated RawKeyboard still exposes those flags, so
/// keep the last raw state here and fall back to it.
class RawModifiers {
  static bool ctrl = false;
  static bool alt = false;
  static bool meta = false;
  static bool shift = false;

  static bool get any => ctrl || alt || meta || shift;

  static bool _listening = false;

  /// Idempotent; called on the first chord so tests and headless callers that
  /// never press a key pay nothing.
  static void listen() {
    if (_listening) return;
    _listening = true;
    // ignore: deprecated_member_use
    RawKeyboard.instance.addListener((RawKeyEvent e) {
      // ignore: deprecated_member_use
      ctrl = e.isControlPressed;
      // ignore: deprecated_member_use
      alt = e.isAltPressed;
      // ignore: deprecated_member_use
      meta = e.isMetaPressed;
      // ignore: deprecated_member_use
      shift = e.isShiftPressed;
    });
  }

  /// Read a raw-layer flag, making sure the listener is installed first (the
  /// editor may ask before any key has gone through [chordFromKeyEvent]).
  static bool listenThen(bool Function() get) {
    listen();
    return get();
  }

  /// Tests only: pretend the raw layer saw these modifiers.
  static void debugSet({
    bool ctrl = false,
    bool alt = false,
    bool meta = false,
    bool shift = false,
  }) {
    RawModifiers.ctrl = ctrl;
    RawModifiers.alt = alt;
    RawModifiers.meta = meta;
    RawModifiers.shift = shift;
  }
}

/// Modifier state as the rest of the editor should read it.
///
/// Everything outside the keymap — ctrl+wheel zoom, shift+wheel, alt+click, the
/// hex view's shift/ctrl — used to ask [HardwareKeyboard] directly, which is
/// permanently empty on a machine where the modifiers arrive only as NSEvent
/// flags (Karabiner-Elements and friends; see [RawModifiers]). Those features
/// then silently did nothing, exactly like the shortcuts did.
class Mods {
  static bool get _hkAny {
    final hk = HardwareKeyboard.instance;
    return hk.isControlPressed ||
        hk.isAltPressed ||
        hk.isMetaPressed ||
        hk.isShiftPressed;
  }

  static bool get ctrl => _hkAny
      ? HardwareKeyboard.instance.isControlPressed
      : (RawModifiers.listenThen(() => RawModifiers.ctrl));
  static bool get alt => _hkAny
      ? HardwareKeyboard.instance.isAltPressed
      : (RawModifiers.listenThen(() => RawModifiers.alt));
  static bool get meta => _hkAny
      ? HardwareKeyboard.instance.isMetaPressed
      : (RawModifiers.listenThen(() => RawModifiers.meta));
  static bool get shift => _hkAny
      ? HardwareKeyboard.instance.isShiftPressed
      : (RawModifiers.listenThen(() => RawModifiers.shift));

  /// The "accelerator" modifier, matching what the keymaps mean by `ctrl`:
  /// ⌘ on macOS, Control elsewhere. macOS also reserves ⌃+scroll for the
  /// system's screen zoom, which is the other reason not to use Control there.
  static bool get accel => Platform.isMacOS ? (meta || ctrl) : ctrl;
}

/// The chord for a key event, or null for a bare modifier / unnamed key.
KeyChord? chordFromKeyEvent(KeyEvent e) {
  RawModifiers.listen();
  final hk = HardwareKeyboard.instance;
  var ctrl = hk.isControlPressed;
  var alt = hk.isAltPressed;
  var meta = hk.isMetaPressed;
  var shift = hk.isShiftPressed;
  // Only when the modern API knows of no modifier at all — a normal keyboard is
  // never overridden, and a stale raw state can never add a modifier to a chord
  // HardwareKeyboard already described.
  if (!ctrl && !alt && !meta && !shift && RawModifiers.any) {
    ctrl = RawModifiers.ctrl;
    alt = RawModifiers.alt;
    meta = RawModifiers.meta;
    shift = RawModifiers.shift;
  }
  final mods = <String>{};
  if (ctrl) mods.add('ctrl');
  if (alt) mods.add('alt');
  if (meta) mods.add('meta');

  final named = keyNameOf(e.logicalKey);
  if (named != null) {
    if (shift) mods.add('shift');
    return KeyChord(mods, named);
  }
  final ch = e.character;
  // A bare ASCII control character (0x01-0x1A) with no modifier state reported:
  // some keyboards / remappers deliver Control chords this way on macOS — the
  // event carries the control code (Ctrl+X -> 0x18) but the Control flag never
  // reaches HardwareKeyboard. Without this the chord would be that invisible
  // character, which matches no binding and silently does nothing.
  if (ch != null && ch.length == 1 && mods.isEmpty) {
    final code = ch.codeUnitAt(0);
    if (code >= 0x01 && code <= 0x1a) {
      final m = <String>{'ctrl'};
      if (shift) m.add('shift');
      return KeyChord(m, String.fromCharCode(code + 0x60)); // 0x18 -> 'x'
    }
  }
  // Symbols (: / $ …): with no modifiers use the character; shift is already
  // reflected in the symbol itself
  if (ch != null &&
      ch.length == 1 &&
      mods.isEmpty &&
      !RegExp(r'[A-Za-z0-9]').hasMatch(ch)) {
    return KeyChord(mods, ch);
  }
  // Letters/digits: use keyLabel (available even while ctrl is held)
  final lbl = e.logicalKey.keyLabel;
  if (lbl.length == 1) {
    final c = lbl.toLowerCase();
    if (RegExp(r'[a-z]').hasMatch(c)) {
      if (shift) mods.add('shift');
      return KeyChord(mods, c);
    }
    // Digits/symbols: keyLabel is the unshifted glyph. Pressed alone, shift is
    // already reflected in `character` (the path above), but combined with
    // ctrl/alt the shift modifier must be added explicitly -- otherwise
    // ctrl+shift+/ collapses into the same chord as ctrl+/.
    if (shift && mods.isNotEmpty) mods.add('shift');
    return KeyChord(mods, c);
  }
  return null;
}

final Map<LogicalKeyboardKey, String> _fnKeys = {
  LogicalKeyboardKey.f1: 'f1',
  LogicalKeyboardKey.f2: 'f2',
  LogicalKeyboardKey.f3: 'f3',
  LogicalKeyboardKey.f4: 'f4',
  LogicalKeyboardKey.f5: 'f5',
  LogicalKeyboardKey.f6: 'f6',
  LogicalKeyboardKey.f7: 'f7',
  LogicalKeyboardKey.f8: 'f8',
  LogicalKeyboardKey.f9: 'f9',
  LogicalKeyboardKey.f10: 'f10',
  LogicalKeyboardKey.f11: 'f11',
  LogicalKeyboardKey.f12: 'f12',
};

/// Keymap name of a named (non-character) key, null for anything else.
String? keyNameOf(LogicalKeyboardKey k) {
  final fn = _fnKeys[k];
  if (fn != null) return fn;
  if (k == LogicalKeyboardKey.escape) return 'escape';
  if (k == LogicalKeyboardKey.enter) return 'enter';
  if (k == LogicalKeyboardKey.tab) return 'tab';
  if (k == LogicalKeyboardKey.backspace) return 'backspace';
  if (k == LogicalKeyboardKey.delete) return 'delete';
  if (k == LogicalKeyboardKey.arrowUp) return 'up';
  if (k == LogicalKeyboardKey.arrowDown) return 'down';
  if (k == LogicalKeyboardKey.arrowLeft) return 'left';
  if (k == LogicalKeyboardKey.arrowRight) return 'right';
  if (k == LogicalKeyboardKey.home) return 'home';
  if (k == LogicalKeyboardKey.end) return 'end';
  if (k == LogicalKeyboardKey.pageUp) return 'pageup';
  if (k == LogicalKeyboardKey.pageDown) return 'pagedown';
  if (k == LogicalKeyboardKey.space) return 'space';
  return null;
}
