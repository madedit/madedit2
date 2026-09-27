import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../util/log.dart';
import 'settings_paths.dart';

export 'settings_paths.dart' show settingsDir, settingsPath;

/// Startup work main() runs after the first frame (seeding settings/, loading
/// user scripts): the shell awaits it before announcing script updates.
/// Null in widget tests (nothing deferred there).
Future<void>? deferredStartup;

// The asset manifest is decoded once per process (seeding, grammar discovery
// and script seeding all list it).
Future<AssetManifest>? _manifest;
Future<AssetManifest> _assetManifest() =>
    _manifest ??= AssetManifest.loadFromAssetBundle(rootBundle);

/// Bundled asset keys under [prefix] (e.g. `assets/l10n/`), from the manifest
/// decoded once per process. Empty when the manifest is unavailable (tests
/// without a bundle).
Future<List<String>> listBundledAssets(String prefix) async {
  try {
    final m = await _assetManifest();
    return m.listAssets().where((a) => a.startsWith(prefix)).toList();
  } catch (_) {
    return const [];
  }
}

/// Config loading: prefer external files under the `settings/` directory next to
/// the executable; if not found or unreadable, fall back to bundled assets (assets/).
/// Covers keymaps / menus / l10n / grammars.
/// Each load is recorded to [Log] (external as info, bundled as debug), making it easy
/// to see "which settings were actually loaded from where".
///
/// Design:
///   - Paths mirror the assets structure: `assets/keymaps/x.json` ↔ `<exe>/settings/keymaps/x.json`.
///   - On first run, [seedConfigFiles] copies the bundled defaults to `settings/` (existing files are not overwritten, preserving user edits).
///   - [loadConfigString] reads the external file and validates that it is valid JSON; if missing / IO error / parse failure → fall back to bundled default + warning.
///
/// Note: uses dart:io, so it is limited to desktop / mobile native platforms (this project targets desktop primarily).
///
/// In dev (`flutter run`), the "executable directory" is `build\...\runner\Debug\`, which `flutter clean` will wipe;
/// for release / after install, the `settings/` next to the exe is the persistent location.

// Prefixes (relative to assets/) to seed-copy from assets/ to settings/. Add new categories here.
// Note: grammars/ is deliberately NOT listed — the ~50 bundled WASM grammars are 70 MB, and seeding
// would both double that on disk and freeze users on the version copied at first run (seeding never
// overwrites). They are read straight out of the bundle instead; a user's settings/grammars/<lang>/
// still wins, since every loader here prefers external settings/.
// l10n and keymaps are deliberately absent: a seeded copy is a snapshot of one
// version's content, and it then masks every later change (the loaders prefer
// the external file). Neither needs a local copy to run — translations ship in
// the bundle and a keymap preset is read-only content whose override mechanism
// is settings/keymaps/user.json — so only a file the user deliberately put
// there counts, and that one is unambiguously theirs.
const List<String> _configPrefixes = [
  'menus/',
  'highlight.json', // single file: lexer config of the pure-Dart highlighter
  'outline.json', // single file: document outline rules
  'toolbar.json', // single file: toolbar definition
  'scripts/', // example user script (settings/scripts/ is where scripts live)
];

/// Read a config file as a string: external `settings/` first (and validate it is valid JSON), otherwise fall back to bundled `assets/`.
///
/// [rel] is of the form `keymaps/default.json`, `menus/main_menu.json`, `l10n/app_en.arb`.
Future<String> loadConfigString(String rel) async {
  final f = File(settingsPath(rel));
  if (await f.exists()) {
    try {
      final s = await f.readAsString(encoding: utf8);
      jsonDecode(s); // validate (all three categories are JSON); a corrupt file goes through catch and falls back to default
      Log.instance.i('config loaded (external settings): $rel');
      return s;
    } catch (e) {
      Log.instance.w('config read failed, using bundled default: ${f.path} ($e)');
    }
  }
  Log.instance.d('config loaded (bundled default): $rel');
  return rootBundle.loadString('assets/$rel');
}

/// Read a config file as a string but **without validating JSON** (for non-JSON text such as `.scm`): external `settings/` first, falling back to bundled.
Future<String> loadConfigText(String rel) async {
  final f = File(settingsPath(rel));
  if (await f.exists()) {
    try {
      final s = await f.readAsString(encoding: utf8);
      Log.instance.i('config loaded (external settings): $rel');
      return s;
    } catch (e) {
      Log.instance.w('config read failed, using bundled default: ${f.path} ($e)');
    }
  }
  Log.instance.d('config loaded (bundled default): $rel');
  return rootBundle.loadString('assets/$rel');
}

/// Read a config file as bytes (binaries such as grammar `.wasm`): external `settings/` first, falling back to bundled `assets/`.
Future<Uint8List> loadConfigBytes(String rel) async {
  final f = File(settingsPath(rel));
  if (await f.exists()) {
    try {
      final b = await f.readAsBytes();
      Log.instance.i('config loaded (external settings): $rel (${b.length} bytes)');
      return b;
    } catch (e) {
      Log.instance.w('config read failed, using bundled default: ${f.path} ($e)');
    }
  }
  Log.instance.d('config loaded (bundled default): $rel');
  final data = await rootBundle.load('assets/$rel');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// Read a JSON config as **bundled defaults with the external file layered on
/// top**, entry by entry.
///
/// `settings/` is seeded once and never overwritten, so an external file that
/// simply replaces the bundled one freezes that config at whatever the app
/// shipped when the user first launched: a new version's languages, rules or
/// strings never arrive. Layering keeps the user's edits winning while new
/// entries appear on their own.
///
/// [listById] names top-level keys holding a list of objects identified by the
/// given field (highlight.json's `languages`, keyed by `name`); [mapKeys] names
/// top-level keys holding an object (outline.json's `languages`). Anything else
/// is taken from the external file when it has it, else from the bundled one.
Future<Map<String, Object?>> loadConfigJsonMerged(
  String rel, {
  Map<String, String> listById = const {},
  Set<String> mapKeys = const {},
}) async {
  Map<String, Object?> parse(String raw) =>
      (jsonDecode(raw) as Map).cast<String, Object?>();

  final bundled = parse(await rootBundle.loadString('assets/$rel'));
  Map<String, Object?> external;
  final f = File(settingsPath(rel));
  try {
    if (!await f.exists()) return bundled;
    external = parse(await f.readAsString(encoding: utf8));
  } catch (e) {
    Log.instance.w('config read failed, using bundled default: ${f.path} ($e)');
    return bundled;
  }

  // The snapshot of the bundled config this file was last reconciled with.
  // Without it an untouched external copy — which is just an old version's
  // bundled file — masks every entry a later version *changed*, not only the
  // ones it added: `external wins` cannot tell "the user edited this" from
  // "this is what the app shipped back then".
  final baseFile = File(settingsPath(_baseNameOf(rel)));
  Map<String, Object?>? base;
  try {
    if (await baseFile.exists()) base = parse(await baseFile.readAsString());
  } catch (e) {
    Log.instance.w('$rel: base snapshot unreadable ($e)');
  }

  /// external's value, unless it is untouched since [base] — then the bundled
  /// one, so the new version's change comes through. No snapshot yet (an
  /// existing user's first run): keep theirs, exactly as before.
  Object? pick(String key, Object? b, Object? x) {
    if (base == null || !base.containsKey(key)) return x ?? b;
    return _sameJson(x, base[key]) ? (b ?? x) : (x ?? b);
  }

  final out = <String, Object?>{};
  for (final k in {...bundled.keys, ...external.keys}) {
    out[k] = pick(k, bundled[k], external[k]);
  }
  for (final e in listById.entries) {
    final b = bundled[e.key], x = external[e.key];
    if (b is! List || x is! List) continue;
    final baseById = _listById(base?[e.key], e.value);
    final bById = _listById(b, e.value);
    final merged = <Object?>[];
    final taken = <String>{};
    for (final item in x) {
      final id = item is Map ? item[e.value] : null;
      if (id is! String) {
        merged.add(item);
        continue;
      }
      taken.add(id);
      // Untouched since the snapshot → take the bundled entry (it may have
      // gained rules or fixes); edited → keep the user's.
      merged.add(
        baseById.containsKey(id) && _sameJson(item, baseById[id])
            ? (bById[id] ?? item)
            : item,
      );
    }
    // Bundled entries the external file does not define, in their original order.
    final extra = [
      for (final item in b)
        if (!(item is Map && taken.contains(item[e.value]))) item,
    ];
    out[e.key] = [...merged, ...extra];
  }
  for (final k in mapKeys) {
    final b = bundled[k], x = external[k];
    if (b is! Map || x is! Map) continue;
    final bm = b.cast<String, Object?>(), xm = x.cast<String, Object?>();
    final basem = (base?[k] is Map)
        ? (base![k] as Map).cast<String, Object?>()
        : const <String, Object?>{};
    out[k] = {
      ...bm,
      for (final e in xm.entries)
        e.key: basem.containsKey(e.key) && _sameJson(e.value, basem[e.key])
            ? (bm[e.key] ?? e.value)
            : e.value,
    };
  }
  // Record what we reconciled against, for the next version's comparison.
  try {
    await baseFile.parent.create(recursive: true);
    await baseFile.writeAsString(jsonEncode(bundled));
  } catch (e) {
    Log.instance.w('$rel: base snapshot write failed ($e)');
  }
  final added = <String>[
    for (final e in listById.entries)
      if (out[e.key] is List && external[e.key] is List &&
          (out[e.key] as List).length > (external[e.key] as List).length)
        '${e.key} +${(out[e.key] as List).length - (external[e.key] as List).length}',
    for (final k in mapKeys)
      if (out[k] is Map && external[k] is Map &&
          (out[k] as Map).length > (external[k] as Map).length)
        '$k +${(out[k] as Map).length - (external[k] as Map).length}',
  ];
  Log.instance.i(
    'config loaded (external settings, layered on bundled): $rel'
    '${added.isEmpty ? '' : ' — filled in ${added.join(', ')}'}',
  );
  return out;
}

/// List the bundled assets under `assets/[prefix]` and return their paths relative to `assets/`
/// (e.g. prefix `grammars/` -> `grammars/rust/tree-sitter-rust.wasm`).
///
/// Used for categories whose contents are not known up front (grammars: one directory per language),
/// so they can be discovered in the bundle the same way a directory scan discovers them in settings/.
/// Returns an empty list on failure (e.g. no asset manifest in a widget test).
Future<List<String>> listBundledConfigs(String prefix) async {
  try {
    final manifest = await _assetManifest();
    final full = 'assets/$prefix';
    return [
      for (final a in manifest.listAssets())
        if (a.startsWith(full)) a.substring('assets/'.length),
    ];
  } catch (e) {
    Log.instance.w('asset manifest read failed (bundled $prefix unavailable): $e');
    return const [];
  }
}

/// On first run, copy the bundled config defaults to `settings/` (existing files are not overwritten).
///
/// Failure (e.g. an unwritable directory) does not block startup: afterwards [loadConfigString] still falls back to the bundled default.
Future<void> seedConfigFiles() async {
  try {
    final manifest = await _assetManifest();
    final copied = <String>[];
    for (final asset in manifest.listAssets()) {
      if (!asset.startsWith('assets/')) continue;
      final rel = asset.substring('assets/'.length); // e.g. keymaps/default.json
      if (!_configPrefixes.any(rel.startsWith)) continue;
      if (rel.startsWith('scripts/')) continue; // see _seedScripts below
      final dest = File(settingsPath(rel));
      if (await dest.exists()) continue; // do not overwrite what the user has modified
      await dest.parent.create(recursive: true);
      final data = await rootBundle.load(asset);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      await dest.writeAsBytes(bytes);
      copied.add(rel);
      // Layered configs (loadConfigJsonMerged) tell "user-edited" from
      // "untouched but old" by comparing against <name>.base.json. Record
      // the seeded version right here: without it the first later version
      // had no snapshot, kept the external values, and every entry that had
      // changed in between stayed frozen at the seeded version for good
      // (only additions came through).
      if (_layeredConfigs.contains(rel)) {
        await File(settingsPath(_baseNameOf(rel))).writeAsBytes(bytes);
      }
    }
    // Sweep away copies left by the old seeding that are byte-identical to the
    // bundled file: pure leftovers, no user edits to lose, and keeping them
    // would freeze that content at the version they were seeded from. An edited
    // one is left alone.
    await _dropPristineSeeds(manifest, const ['l10n/', 'keymaps/']);
    scriptsWithNewVersion = await _seedScripts(manifest);
    if (copied.isNotEmpty) {
      Log.instance.i('seeded ${copied.length} config file(s) to settings/: $copied');
    } else {
      Log.instance.d('seed: settings/ already has all defaults, nothing copied');
    }
  } catch (e) {
    Log.instance.w('seed copy failed (will run with bundled defaults): $e');
  }
}

/// Delete seeded copies under [prefixes] that still match the bundle exactly.
///
/// `keymaps/user.json` is never a bundled asset, so a user's own overrides are
/// not even considered here.
Future<void> _dropPristineSeeds(
  AssetManifest manifest,
  List<String> prefixes,
) async {
  for (final asset in manifest.listAssets()) {
    if (!prefixes.any((p) => asset.startsWith('assets/$p'))) continue;
    final rel = asset.substring('assets/'.length);
    final f = File(settingsPath(rel));
    try {
      if (!await f.exists()) continue;
      final data = await rootBundle.load(asset);
      final bundled = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final local = await f.readAsBytes();
      if (local.length != bundled.length) continue;
      var same = true;
      for (var i = 0; i < local.length && same; i++) {
        same = local[i] == bundled[i];
      }
      if (!same) continue; // edited: leave it alone
      await f.delete();
      Log.instance.i('removed pristine seeded copy: $rel');
    } catch (_) {
      // Unreadable / undeletable: harmless, the layering still applies.
    }
  }
}

String _baseNameOf(String rel) => rel.replaceFirst(RegExp(r'\.json$'), '.base.json');

/// Configs read through [loadConfigJsonMerged] (bundled base + external
/// overrides + base snapshot); seeding writes their snapshot too.
const Set<String> _layeredConfigs = {'highlight.json', 'outline.json'};

bool _sameJson(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

Map<String, Object?> _listById(Object? list, String idKey) => {
  if (list is List)
    for (final item in list)
      if (item is Map && item[idKey] is String) item[idKey] as String: item,
};

/// Built-in scripts whose bundled version changed while the user had edited
/// their copy: the new text was written beside it as `<name>.new` and the UI
/// points the user at Tools → Script Updates. The `.new` file *is* the state — the
/// notice lasts exactly as long as it does, so nothing has to be remembered.
List<String> scriptsWithNewVersion = const [];

/// Seed `scripts/`, updating the built-ins the user has not touched.
///
/// A plain "copy when absent" freezes every built-in at the version the user
/// first launched, so a fixed script never reaches them; blindly overwriting
/// would throw away their edits. Keeping the exact bytes we seeded (under
/// `scripts/.seeded/`) tells the two apart — a byte comparison rather than a
/// hash, so no collision can ever cost someone their script, and 15 KB is
/// nothing next to what this app already ships:
///
///   file absent                  seed it
///   file == bundled              already current
///   file == what we seeded       untouched → overwrite with the new one
///   otherwise                    theirs → write `<name>.new` and notify
///
/// A `.new` file is inert: the registry only picks up `.js` / `.lua`.
Future<List<String>> _seedScripts(AssetManifest manifest) async {
  final pending = <String>[];
  final copied = <String>[];

  Future<bool> sameBytes(File f, Uint8List b) async {
    try {
      if (!await f.exists()) return false;
      final a = await f.readAsBytes();
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  for (final asset in manifest.listAssets()) {
    if (!asset.startsWith('assets/scripts/')) continue;
    final rel = asset.substring('assets/'.length);
    final name = rel.substring('scripts/'.length);
    try {
      final data = await rootBundle.load(asset);
      final bundled = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final dest = File(settingsPath(rel));
      final seeded = File(settingsPath('scripts/.seeded/$name'));

      Future<void> take() async {
        await dest.parent.create(recursive: true);
        await dest.writeAsBytes(bundled);
        copied.add(name);
      }

      Future<void> remember() async {
        await seeded.parent.create(recursive: true);
        await seeded.writeAsBytes(bundled);
      }

      if (!await dest.exists()) {
        await take();
      } else if (await sameBytes(dest, bundled)) {
        // Already this version — nothing to do but record it.
      } else if (await sameBytes(seeded, await dest.readAsBytes())) {
        await take(); // untouched since we seeded it, and the bundle moved on
      } else {
        // "Keep mine" was chosen for THIS bundled version (the shell records
        // the dismissed bytes): not outstanding. Without the marker the .new
        // was parked again on every launch and the notice never went away;
        // a later bundled version differs from the marker and asks again.
        if (await sameBytes(File('${seeded.path}.dismissed'), bundled)) {
          continue;
        }
        // Theirs. Leave it running and park the new one beside it; the update
        // stays outstanding, so the seeded copy is deliberately NOT updated.
        final side = File('${dest.path}.new');
        if (!await sameBytes(side, bundled)) {
          await side.parent.create(recursive: true);
          await side.writeAsBytes(bundled);
        }
        pending.add(name);
        continue;
      }
      await remember();
    } catch (e) {
      Log.instance.w('script seed failed: $rel ($e)');
    }
  }

  // A `.new` from an earlier run that the user has not dealt with yet.
  try {
    final dir = Directory(settingsPath('scripts'));
    if (await dir.exists()) {
      await for (final f in dir.list()) {
        if (f is! File || !f.path.endsWith('.new')) continue;
        final n = f.path.split(Platform.pathSeparator).last;
        final base = n.substring(0, n.length - '.new'.length);
        if (!pending.contains(base)) pending.add(base);
      }
    }
  } catch (_) {}

  if (copied.isNotEmpty) {
    Log.instance.i('built-in scripts seeded/updated: $copied');
  }
  if (pending.isNotEmpty) {
    Log.instance.i('scripts with a new version parked as .new: $pending');
  }
  pending.sort();
  return pending;
}
