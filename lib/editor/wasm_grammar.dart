import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../settings/config_loader.dart';
import '../util/log.dart';

/// A loaded WASM grammar (plugin): grammar bytes + highlights query.
class WasmGrammar {
  /// A grammar whose bytes are already in memory (tests).
  WasmGrammar(this.lang, Uint8List wasm, String query)
    : _wasm = wasm,
      _query = query,
      wasmRel = '',
      queryRel = '';

  /// A grammar known only by its files; [ensureLoaded] reads them on first
  /// use. Startup registers ~50 languages (70 MB of wasm): reading all of it
  /// up front cost 0.1–0.8 s and held the bytes for the whole run, while a
  /// session touches a handful of languages.
  WasmGrammar.lazy(this.lang, this.wasmRel, this.queryRel)
    : _wasm = null,
      _query = null;

  /// Language name; must match the wasm-exported `tree_sitter_<lang>`.
  final String lang;

  /// Paths relative to assets/ resp. settings/ (`grammars/<lang>/x.wasm`).
  final String wasmRel;
  final String queryRel;

  Uint8List? _wasm;
  String? _query;
  Future<void>? _loading;

  bool get isLoaded => _wasm != null;

  /// The grammar's `.wasm` bytes. Only valid once [isLoaded].
  Uint8List get wasm => _wasm!;

  /// Highlights query (contents of the `.scm` file). Only valid once [isLoaded].
  String get query => _query!;

  /// Read the wasm and query (once; concurrent callers share the read).
  Future<void> ensureLoaded() {
    if (_wasm != null) return Future.value();
    return _loading ??= () async {
      final sw = Stopwatch()..start();
      final w = await loadConfigBytes(wasmRel);
      final q = await loadConfigText(queryRel);
      _query = q;
      _wasm = w;
      Log.instance.d(
        'grammar read: $lang (${(w.length / 1024).round()} KB wasm, '
        '${q.length} char query, ${sw.elapsedMilliseconds} ms)',
      );
    }();
  }
}

/// WASM grammar registry: on startup, **auto-scans** the grammar directories
/// and loads the installed languages.
///
/// One language = one directory `grammars/<lang>/`, containing:
///   - any `*.wasm`     grammar (**required**; the first .wasm in the directory, name doesn't matter --
///                       the `tree-sitter-<lang>.wasm` downloaded from tree-sitter-wasms can be dropped in as-is, no renaming needed)
///   - `highlights.scm`  highlights query (**required**; the grammar's official repo usually ships a standard one)
///   - `grammar.json`    meta (**optional**): `{ "language": "<tree_sitter name>", "extensions": ["ext", ...] }`
///                       when omitted: language name = directory name, extension = directory name.
///                       -> when the extension equals the language name (e.g. json/dart/go) only the first two files are needed; when the extension differs
///                          (python->py, rust->rs) or a language has multiple extensions (c->c,h), grammar.json is needed.
///
/// Note: the grammar's "language name" (for `tree_sitter_<lang>`) comes from the **directory name or grammar.json**, and is unrelated to the .wasm
/// file name, so the .wasm file name can be anything. The directory name must use the tree_sitter name (e.g. `json`, `python`).
///
/// Two sources, scanned in this order:
///   1. bundled `assets/grammars/` -- the ~50 languages shipped with the app (listed in pubspec by
///      `tool/gen_grammar_assets.dart`; Flutter asset directory entries are not recursive, hence one line per language)
///   2. external `settings/grammars/` -- what the user installed themselves (`third-party/build_grammars.py`)
/// A language present in both is taken from settings/, so a user can replace a bundled grammar with their own
/// build. "Installing a language" = dropping that directory into `settings/grammars/`; it takes effect on
/// restart (no code changes needed). Bundled grammars are read out of the bundle, never copied to settings/.
class WasmGrammarRegistry {
  WasmGrammarRegistry._();
  static final WasmGrammarRegistry instance = WasmGrammarRegistry._();

  final Map<String, WasmGrammar> _byExt = {}; // extension (lowercase) -> grammar
  final Map<String, WasmGrammar> _byLang = {}; // language name -> grammar

  /// The loaded language names (sorted).
  List<String> get languages => _byLang.keys.toList()..sort();

  /// Whether this extension has an installed WASM grammar.
  WasmGrammar? forExt(String ext) => _byExt[ext.toLowerCase()];

  /// Extensions the installed grammars map to [lang] (sorted).
  List<String> extensionsFor(String lang) =>
      [for (final e in _byExt.entries) if (e.value.lang == lang) e.key]..sort();

  /// Look up a grammar by language name (used by the menubar to manually pick a syntax).
  WasmGrammar? forLang(String lang) => _byLang[lang];

  Future<void>? _loading;

  /// Completes when [load] has listed the grammars (immediately when it was
  /// never started, e.g. widget tests). main() starts the scan without
  /// awaiting it so the first frame is not held back; a document opening
  /// meanwhile waits here before picking its highlighter.
  Future<void> get ready => _loading ?? Future.value();

  /// Call once on startup: scan and load all installed grammars (languages that fail to read are skipped, and don't block startup).
  Future<void> load() => _loading = _load();

  Future<void> _load() async {
    _byExt.clear();
    _byLang.clear();
    // lang (directory name) -> wasm relative path (grammars/<lang>/<name>.wasm).
    final found = await _discoverGrammars();
    final skipped = <String>[];
    for (final dir in found.entries) {
      final lang = dir.key;
      try {
        // grammar.json is optional: it provides language (default: directory name) and extensions (default: directory name).
        var langName = lang;
        var exts = <String>[lang];
        try {
          final meta = (jsonDecode(await loadConfigText('grammars/$lang/grammar.json')) as Map)
              .cast<String, Object?>();
          langName = (meta['language'] as String?) ?? lang;
          final e = (meta['extensions'] as List?)?.cast<String>();
          if (e != null && e.isNotEmpty) exts = e;
        } catch (_) {
          // No grammar.json -> use defaults (directory name as both language name and extension).
        }
        // Neither the wasm nor the query is read here: WasmGrammar.ensureLoaded
        // does that on the language's first use, and compiling (validating)
        // the wasm via `registerWasmGrammar` happens then too — see
        // RustHighlighter._register. Startup only learns which languages and
        // extensions exist. A missing/incompatible file shows up as "no
        // highlighting" for that language, logged at that point.
        final g = WasmGrammar.lazy(
          langName,
          dir.value,
          'grammars/$lang/highlights.scm',
        );
        _byLang[langName] = g;
        for (final e in exts) {
          _byExt[e.toLowerCase()] = g;
        }
      } catch (e) {
        Log.instance.w('grammar skipped: $lang ($e)');
        skipped.add(lang);
      }
    }
    // One line summarizing which grammars were loaded: language count + the
    // sorted language list (the actual wasm compile is deferred to the first
    // highlight of that language; see the log in RustHighlighter._register).
    Log.instance.i(
      'WASM grammars loaded: ${_byLang.length} languages $languages, '
      'covering ${_byExt.length} extensions'
      '${skipped.isEmpty ? '' : '; skipped ${skipped.length}: $skipped'}',
    );
    Log.instance.d('grammar extension map: ${_extMapText()}');
  }

  // "ext -> language" as one sorted line, for the log.
  String _extMapText() {
    final exts = _byExt.keys.toList()..sort();
    return [for (final e in exts) '$e→${_byExt[e]!.lang}'].join(', ');
  }

  // "language name (directory name) -> relative path of the first .wasm in that directory", merged from
  // the bundle and settings/. Bundled first, then settings/ overwrites, so a user-installed language of
  // the same name wins (the loaders in config_loader.dart prefer settings/ for the file contents too).
  // The paths returned are relative to assets/ resp. settings/, i.e. `grammars/<lang>/<file>.wasm`.
  Future<Map<String, String>> _discoverGrammars() async {
    final out = <String, String>{};
    // 1. bundled: pick the first .wasm listed under each assets/grammars/<lang>/.
    for (final rel in await listBundledConfigs('grammars/')) {
      if (!rel.toLowerCase().endsWith('.wasm')) continue;
      final parts = rel.split('/'); // asset keys always use '/', even on Windows
      if (parts.length != 3) continue; // grammars/<lang>/<file>.wasm
      out.putIfAbsent(parts[1], () => rel);
    }
    // 2. external settings/grammars/: overrides a bundled language of the same name.
    try {
      final sep = Platform.pathSeparator;
      final base = Directory('$settingsDir${sep}grammars');
      if (await base.exists()) {
        await for (final d in base.list()) {
          if (d is! Directory) continue;
          final lang = d.path.split(sep).last;
          await for (final f in d.list()) {
            if (f is File && f.path.toLowerCase().endsWith('.wasm')) {
              out[lang] = 'grammars/$lang/${f.path.split(sep).last}';
              break;
            }
          }
        }
      }
    } catch (_) {}
    return out;
  }
}
