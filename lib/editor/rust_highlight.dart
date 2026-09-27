// Dart wrapper for tree-sitter syntax highlighting (backend in Rust, cross-platform via
// flutter_rust_bridge).
//
// The Rust side `highlight(lang, source)` returns "byte-range spans over the joined text"; those
// are mapped back to per-line UTF-16 character spans (see hl_span_map.dart) to plug into the
// existing [Highlighter] interface and render pipeline. Nested priority (inner overrides) is
// already handled by tree-sitter-highlight, and Source events are non-overlapping and in order.
//
// Requires `RustLib.init()` first (already called in main). The native library is produced by
// cargokit during each platform's build.

import '../src/rust/api/highlight.dart' as rust;
import '../util/log.dart';
import 'highlight.dart';
import 'hl_span_map.dart';
import 'wasm_grammar.dart';

class RustHighlighter implements Highlighter {
  /// Use a **statically compiled-in** grammar (currently 'json').
  RustHighlighter(this.lang) : _wasm = null;

  /// Use a **WASM grammar loaded dynamically at runtime** (a plugin).
  RustHighlighter.wasm(WasmGrammar grammar)
    : lang = grammar.lang,
      _wasm = grammar;

  /// Grammar name.
  final String lang;

  /// Non-null = WASM grammar path; null = statically compiled-in grammar.
  final WasmGrammar? _wasm;

  /// Languages whose WASM grammar has already been registered (compiled + cached) in Rust, so the
  /// multi-MB wasm bytes are handed across the FFI boundary only once, not on every highlight call.
  static final Set<String> _registered = {};

  /// The plugin grammar behind this highlighter (null for a built-in one).
  WasmGrammar? get grammar => _wasm;

  @override
  String get description => _wasm != null
      ? 'WASM grammar "$lang" (grammars/$lang)'
      : 'built-in tree-sitter grammar "$lang"';

  /// Whether this extension has a corresponding **statically compiled-in** tree-sitter grammar.
  static bool supports(String ext) {
    try {
      return rust.supportedLanguage(ext: ext.toLowerCase());
    } catch (_) {
      return false; // native library not ready
    }
  }

  @override
  List<List<HlSpan>> highlight(List<String> lines) {
    if (lines.isEmpty) return const [];
    final source = lines.join('\n');
    final List<rust.HlSpan> spans;
    // Synchronous, on the UI thread. Normally milliseconds; a first use after
    // the pool ran dry (a session holds one) compiles the grammar here.
    final sw = Stopwatch()..start();
    try {
      final w = _wasm;
      if (w != null) {
        // Grammar files not read yet: start that and paint plain for now —
        // the editor repaints once the read completes (see
        // _EditorViewState._resolveHighlighter).
        if (!_register(w)) return [for (final _ in lines) const <HlSpan>[]];
        spans = rust.highlightWasm(lang: w.lang, source: source);
      } else {
        spans = rust.highlight(lang: lang, source: source);
      }
    } catch (_) {
      return [for (final _ in lines) const <HlSpan>[]];
    }
    if (sw.elapsedMilliseconds >= 200) {
      Log.instance.w(
        'slow: sync highlight $lang (${lines.length} lines, ${source.length} chars) '
        'took ${sw.elapsedMilliseconds} ms',
      );
    }
    return mapSpansToLines(lines, spans);
  }

  /// Whole-file highlighting: the parse runs on a Rust worker thread so a multi-MB file does not
  /// freeze the UI isolate. The (cheap) byte→line mapping still happens here.
  @override
  Future<List<List<HlSpan>>> highlightAsync(List<String> lines) async {
    if (lines.isEmpty) return const [];
    final source = lines.join('\n');
    final List<rust.HlSpan> spans;
    try {
      final w = _wasm;
      if (w != null) {
        await w.ensureLoaded();
        _register(w); // sync: it is what makes the language known to Rust
        spans = await rust.highlightWasmOffThread(lang: w.lang, source: source);
      } else {
        spans = await rust.highlightOffThread(lang: lang, source: source);
      }
    } catch (_) {
      return [for (final _ in lines) const <HlSpan>[]];
    }
    return mapSpansToLines(lines, spans);
  }

  @override
  HlSession? createSession() => RustHlSession(this);

  /// First time we highlight this language: hand the wasm + query to Rust once. Afterwards we pass
  /// only (lang, source), so a big grammar (e.g. cpp ~5 MB) is not copied across the FFI boundary
  /// on every scroll frame / keystroke.
  ///
  /// Returns false when the grammar's files are not in memory yet (the read
  /// is started); async callers `await w.ensureLoaded()` first so they never
  /// see that.
  bool _register(WasmGrammar w) {
    if (_registered.contains(w.lang)) return true;
    if (!w.isLoaded) {
      w.ensureLoaded();
      return false;
    }
    _registered.add(w.lang);
    // First actual use of this language: this is where the wasm is compiled, so it is also where
    // an incompatible grammar shows up (it would otherwise just silently produce no colors).
    final sw = Stopwatch()..start();
    final ok = rust.registerWasmGrammar(
      lang: w.lang,
      wasm: w.wasm,
      query: w.query,
    );
    if (ok) {
      // The elapsed time is logged because it is the one blocking step of opening a file in a new
      // language (cranelift compiles the grammar): ~0.1-0.5 s is normal, seconds means something
      // is wrong — see api::simple::init_app about the log level FRB installs on macOS.
      Log.instance.i(
        'WASM grammar compiled: ${w.lang} (${(w.wasm.length / 1024).round()} KB wasm, '
        '${sw.elapsedMilliseconds} ms)',
      );
    } else {
      Log.instance.w(
        'WASM grammar failed to compile: ${w.lang} — the .wasm may be'
        ' incompatible (build it with tree-sitter 0.26+'
        ' `tree-sitter build --wasm`); this language gets no highlighting',
      );
    }
    return true;
  }
}

/// Incremental session backed by a Rust `hl_doc_*` document: Rust keeps the text and syntax tree,
/// re-parses each line replacement against the old tree and returns per-line UTF-16 spans for
/// just the lines whose highlighting changed (so no text has to be read back here).
class RustHlSession implements HlSession {
  RustHlSession(this._h) : id = _nextId++;

  static int _nextId = 1;

  final RustHighlighter _h;
  final int id;
  bool _open = false;

  @override
  Future<List<List<HlSpan>>?> open(List<String> lines) async {
    final w = _h._wasm;
    if (w != null) {
      await w.ensureLoaded();
      _h._register(w);
    }
    final List<rust.HlSpan>? spans;
    try {
      spans = await rust.hlDocOpen(
        id: id,
        lang: _h.lang,
        wasm: w != null,
        source: lines.join('\n'),
      );
    } catch (_) {
      return null;
    }
    if (spans == null) return null;
    _open = true;
    return mapSpansToLines(lines, spans);
  }

  @override
  Future<HlPatch?> edit(
    int start,
    int oldEnd,
    List<String> newLines,
    HlLineReader read,
  ) async {
    if (!_open) return null;
    final rust.HlPatch? p;
    try {
      p = await rust.hlDocEdit(
        id: id,
        startLine: start,
        oldEndLine: oldEnd,
        newLines: newLines,
      );
    } catch (_) {
      return null;
    }
    if (p == null) {
      _open = false; // Rust dropped the session
      return null;
    }
    final n = p.endLine - p.startLine;
    final lines = List.generate(n, (_) => <HlSpan>[]);
    for (final s in p.spans) {
      final i = s.line - p.startLine;
      if (i >= 0 && i < n) lines[i].add(HlSpan(s.start, s.end, s.style));
    }
    return HlPatch(p.startLine, lines);
  }

  @override
  Future<List<FoldRange>?> folds() async {
    if (!_open) return null;
    try {
      final r = rust.hlDocFolds(id: id);
      if (r == null) return null;
      return [for (final f in r) FoldRange(f.startRow, f.endRow)];
    } catch (_) {
      return null;
    }
  }

  @override
  void close() {
    if (!_open) return;
    _open = false;
    try {
      rust.hlDocClose(id: id);
    } catch (_) {}
  }
}
