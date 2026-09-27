// Keyboard access to the menu bar itself (as opposed to Alt+letter
// mnemonics, which MenuAcceleratorLabel handles): which key events mean
// "toggle the menu bar". Pure event logic, no widgets, so it can be tested
// headlessly with synthetic KeyEvents.
//
//   Windows / Linux: F10 with no modifier, or a lone Alt press-and-release
//                    (no other key while it was down) — the native
//                    convention.
//   macOS:           ⌃F2 (the system's "move focus to menu bar" key; ours
//                    is not the native NSMenu, so we handle it ourselves).
//
// Alt+Tab leaves an Alt press pending without its release ever arriving
// (or arriving after the window came back), so the owner must call [reset]
// on window blur.

import 'package:flutter/services.dart';

import '../editor/keybinding/chord_from_event.dart' show Mods;

class MenuBarKeys {
  MenuBarKeys({required this.isMac});

  final bool isMac;

  /// An Alt press is down and nothing else has been pressed since.
  bool _altPending = false;

  static bool _isAlt(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.altLeft ||
      k == LogicalKeyboardKey.altRight ||
      k == LogicalKeyboardKey.alt;

  /// Forget a pending Alt press (window blur, menu opened by other means).
  void reset() => _altPending = false;

  /// True when [e] completes a "toggle the menu bar" gesture. Never consumes
  /// anything else, so the caller can pass every event through here first.
  bool toggles(KeyEvent e) {
    final k = e.logicalKey;
    if (isMac) {
      return e is KeyDownEvent &&
          k == LogicalKeyboardKey.f2 &&
          Mods.ctrl &&
          !Mods.alt &&
          !Mods.meta &&
          !Mods.shift;
    }
    if (e is KeyDownEvent) {
      if (_isAlt(k)) {
        _altPending = true;
        return false;
      }
      // Any other key while Alt is down (Alt+F, Alt+Tab, Alt+Shift…) is a
      // combination, not a tap.
      _altPending = false;
      // Shift+F10 is the context-menu key on Windows; leave it alone.
      return k == LogicalKeyboardKey.f10 &&
          !Mods.ctrl &&
          !Mods.alt &&
          !Mods.meta &&
          !Mods.shift;
    }
    if (e is KeyUpEvent && _isAlt(k)) {
      final tap = _altPending;
      _altPending = false;
      return tap;
    }
    // Key repeat (Alt held down shows the mnemonic underlines) keeps the
    // tap pending; repeats of other keys were already cancelled on their
    // own key-down.
    return false;
  }
}
