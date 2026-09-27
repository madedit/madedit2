// User text-transform scripts (QuickJS / Lua plugins): registry + scan.
//
// One script = one file `settings/scripts/<name>.js` (QuickJS) or `.lua`
// (Lua 5.4); the engine is picked by extension, the host contract is the
// same. A JS script defines a global
//   transformLine(line, lineNo) -> string | null | undefined
// and a Lua script
//   transform_line(line, line_no) -> string | nil
// The Tools menu lists the installed scripts; running one streams the active
// document's lines through the script (see script_transform.dart + the Rust
// side rust/src/api/{script,lua_script}.rs).
//
// Scripts are read from external settings/ only at scan time; [load] runs at
// startup and again from the menu's reload item, so editing a script does not
// require a restart. Each script is registered into its Rust engine right at
// scan time — syntax errors / a missing transform function surface here (kept
// in [errorFor] for a toast when the user tries to run it, and logged).

import 'dart:io';

import '../settings/settings_paths.dart';
import '../src/rust/api/lua_script.dart' as rust_lua;
import '../src/rust/api/script.dart' as rust_js;
import '../util/log.dart';

enum ScriptEngine { js, lua }

class UserScriptRegistry {
  UserScriptRegistry._();
  static final UserScriptRegistry instance = UserScriptRegistry._();

  final Map<String, String> _errors = {}; // name -> registration error
  final Map<String, ScriptEngine> _engines = {}; // name -> engine
  List<String> _names = const [];

  /// Installed script names (file stem, sorted).
  List<String> get names => _names;

  /// Which engine runs [name]; null when unknown.
  ScriptEngine? engineFor(String name) => _engines[name];

  /// The script's registration error (compile failure), or null when it
  /// registered fine.
  String? errorFor(String name) => _errors[name];

  /// Scan `settings/scripts/*.js|*.lua` and (re-)register every script with
  /// its Rust engine. Safe to call again at runtime (menu: reload scripts);
  /// re-registering replaces the old source.
  Future<void> load() async {
    final found = <String, (ScriptEngine, String)>{}; // name -> (engine, source)
    try {
      final sep = Platform.pathSeparator;
      final base = Directory('$settingsDir${sep}scripts');
      if (await base.exists()) {
        await for (final f in base.list()) {
          if (f is! File) continue;
          final file = f.path.split(sep).last;
          final lower = file.toLowerCase();
          final ScriptEngine engine;
          final String name;
          if (lower.endsWith('.js')) {
            engine = ScriptEngine.js;
            name = file.substring(0, file.length - 3);
          } else if (lower.endsWith('.lua')) {
            engine = ScriptEngine.lua;
            name = file.substring(0, file.length - 4);
          } else {
            continue;
          }
          if (found.containsKey(name)) {
            // Menu names are the stem: a.js + a.lua would collide — keep the
            // first found, skip the other with a warning.
            Log.instance.w('script skipped: $file (name "$name" clashes with another script)');
            continue;
          }
          try {
            found[name] = (engine, await f.readAsString());
          } catch (e) {
            Log.instance.w('script skipped: $name (read failed: $e)');
          }
        }
      }
    } catch (_) {}
    _errors.clear();
    _engines.clear();
    _names = found.keys.toList()..sort();
    for (final name in _names) {
      final (engine, source) = found[name]!;
      _engines[name] = engine;
      try {
        final err = switch (engine) {
          ScriptEngine.js =>
            rust_js.jsRegisterScript(name: name, source: source),
          ScriptEngine.lua =>
            rust_lua.luaRegisterScript(name: name, source: source),
        };
        if (err != null) {
          _errors[name] = err;
          Log.instance.w('script failed to compile: $name — $err');
        }
      } catch (e) {
        _errors[name] = e.toString(); // native library not ready
      }
    }
    try {
      rust_js.jsRetainScripts(names: [
        for (final n in _names)
          if (_engines[n] == ScriptEngine.js) n,
      ]);
      rust_lua.luaRetainScripts(names: [
        for (final n in _names)
          if (_engines[n] == ScriptEngine.lua) n,
      ]);
    } catch (_) {}
    Log.instance.i(
      'user scripts loaded: ${_names.length} $_names'
      '${_errors.isEmpty ? '' : '; ${_errors.length} failed to compile '
                '${_errors.keys.toList()}'}',
    );
  }
}
