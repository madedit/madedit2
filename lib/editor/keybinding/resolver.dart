import 'key_chord.dart';
import 'keymap.dart';

enum ResolveKind { fired, pending, none }

class ResolveResult {
  ResolveResult.fired(this.command, this.args, this.count)
    : kind = ResolveKind.fired;
  ResolveResult.pending()
    : kind = ResolveKind.pending,
      command = null,
      args = null,
      count = 0;
  ResolveResult.none()
    : kind = ResolveKind.none,
      command = null,
      args = null,
      count = 0;

  final ResolveKind kind;
  final String? command;
  final Map<String, Object?>? args;
  final int count;
}

class _Node {
  final Map<String, _Node> children = {};
  final List<KeyBinding> terminal = []; // added later = higher priority
}

/// Key resolver: consumes chords, looks up the trie for the current mode, and
/// handles counts and chord prefixes / ambiguity / timeouts.
class Resolver {
  Resolver(Keymap km, List<KeyBinding> effective, {this.ctrlAsMeta = false})
    : defaultMode = km.defaultMode {
    mode = km.defaultMode;
    final byMode = <String?, List<KeyBinding>>{};
    for (final b in effective) {
      (byMode[b.mode] ??= []).add(b);
    }
    final global = byMode[null] ?? const <KeyBinding>[];
    if (defaultMode == null) {
      _tries[null] = _build(global);
    } else {
      final modes = {
        ...byMode.keys.whereType<String>(),
        defaultMode!,
        'normal',
        'insert',
        'visual',
      };
      for (final m in modes) {
        // Mode-specific last = mode-specific wins: a modal preset's `visual`
        // binding for Home must beat the global one it inherited (vim extends
        // default), and "the more specific binding wins" is what a keymap
        // reads like. Within one specificity the later binding still wins, so
        // a user override of a global stays an override.
        _tries[m] = _build([...global, ...(byMode[m] ?? const [])]);
      }
    }
  }

  final String? defaultMode;
  String? mode;

  /// macOS: retry an unbound physical-Control chord as ⌘.
  ///
  /// Keymap files write `ctrl`, which resolves to ⌘ on macOS, so a keyboard
  /// that only ever emits Control (a PC keyboard in Windows mode, a remapper,
  /// a Control key the OS reports without modifier flags) can never reach any
  /// binding. The retry only runs when the Control chord matched nothing, so
  /// an explicit `control+…` binding (vim's control+d/u/f/b) still wins.
  final bool ctrlAsMeta;

  final Map<String?, _Node> _tries = {};
  List<KeyChord> _pending = [];
  int _count = 0;
  KeyBinding? _fallback; // a complete match already seen while pending; fired on timeout

  bool get hasPending => _pending.isNotEmpty || _count > 0;
  String get pendingText =>
      (_count > 0 ? '$_count' : '') +
      _pending.map((c) => c.canonical).join(' ');

  _Node _build(List<KeyBinding> bindings) {
    final root = _Node();
    for (final b in bindings) {
      var node = root;
      for (final c in b.chords) {
        node = node.children.putIfAbsent(c.canonical, () => _Node());
      }
      node.terminal.add(b);
    }
    return root;
  }

  /// Consumes one chord. [context] is used to evaluate `when` (lazily).
  ResolveResult input(KeyChord chord, Map<String, Object?> Function() context) {
    final wasPending = hasPending;
    final res = _input(chord, context);
    // Only retry a fresh, unbound Control chord (mid-sequence a retry could
    // fire something the user never typed).
    if (res.kind != ResolveKind.none ||
        wasPending ||
        !ctrlAsMeta ||
        !chord.mods.contains('ctrl') ||
        chord.mods.contains('meta')) {
      return res;
    }
    final mods = {...chord.mods}
      ..remove('ctrl')
      ..add('meta');
    return _input(KeyChord(mods, chord.key), context);
  }

  ResolveResult _input(
    KeyChord chord,
    Map<String, Object?> Function() context,
  ) {
    // count: modal keymap, not in insert mode, nothing pending, an unmodified digit key
    if (defaultMode != null &&
        _pending.isEmpty &&
        chord.mods.isEmpty &&
        mode != 'insert') {
      final k = chord.key;
      if (k.length == 1) {
        final code = k.codeUnitAt(0);
        if (code >= 0x30 && code <= 0x39) {
          final d = code - 0x30;
          if (!(d == 0 && _count == 0)) {
            _count = _count * 10 + d;
            return ResolveResult.pending();
          }
        }
      }
    }

    final root = _tries[mode] ?? _tries[null];
    if (root == null) {
      _reset();
      return ResolveResult.none();
    }

    final seq = [..._pending, chord];
    var node = root;
    for (final c in seq) {
      final next = node.children[c.canonical];
      if (next == null) {
        _reset();
        return ResolveResult.none();
      }
      node = next;
    }

    final hasPrefix = node.children.isNotEmpty;
    final fired = _pick(node.terminal, context);

    if (fired != null && !hasPrefix) {
      final cnt = _count == 0 ? 1 : _count;
      _reset();
      return ResolveResult.fired(fired.command, fired.args, cnt);
    }
    if (hasPrefix) {
      _pending = seq;
      _fallback = fired; // may be null
      return ResolveResult.pending();
    }
    _reset();
    return ResolveResult.none();
  }

  /// Chord timeout: fires the fallback (a shorter binding that already
  /// matched completely) if there is one.
  ResolveResult? flushTimeout() {
    if (_pending.isNotEmpty && _fallback != null) {
      final f = _fallback!;
      final cnt = _count == 0 ? 1 : _count;
      _reset();
      return ResolveResult.fired(f.command, f.args, cnt);
    }
    _reset();
    return null;
  }

  KeyBinding? _pick(
    List<KeyBinding> terminal,
    Map<String, Object?> Function() context,
  ) {
    if (terminal.isEmpty) return null;
    Map<String, Object?>? ctx;
    for (var i = terminal.length - 1; i >= 0; i--) {
      final b = terminal[i];
      if (b.whenExpr == null) return b;
      ctx ??= context();
      if (b.whenExpr!.eval(ctx)) return b;
    }
    return null;
  }

  void _reset() {
    _pending = [];
    _count = 0;
    _fallback = null;
  }
}
