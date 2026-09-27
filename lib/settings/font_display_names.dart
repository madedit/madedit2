// Localized font family names for the font dialog. Pure Dart (dart:io, ffi
// through util/mac_fonts.dart), headless-testable: tool/font_display_names_test.dart.
//
// The family list itself (system_fonts.dart) is the font's canonical
// English name — on Windows the Fonts registry only stores that ("MingLiU &
// PMingLiU (TrueType)"), CoreText hands back canonical names, fc-list's
// first family entry is the English one. Other editors show "細明體" because
// GDI / DirectWrite pick the `name` table entry for the UI language. This
// file rebuilds that mapping — English family → localized family — and the
// dialog uses it for DISPLAY only; settings keep the English name, which is
// stable across machines and UI languages and is what Flutter's fontFamily
// resolves everywhere.
//
//   Windows  registry name → file (print_fonts.windowsFontRegistry), then
//            the `name` table of every sub-font (three small seeks per font,
//            not a whole-file read).
//   Linux    fc-list --format '%{family}|%{familylang}\n': each family is a
//            comma list with a parallel language list.
//   macOS    CTFontCopyLocalizedName per family (util/mac_fonts.dart); it
//            follows the SYSTEM preferred languages, not the app's locale —
//            same as Font Book / Finder.

import 'dart:io';
import 'dart:isolate';

import '../editor/print_fonts.dart';
import '../util/mac_fonts.dart';

/// Log hook (flutter-free file; the app wires Log into it).
void Function(String msg)? fontNamesLog;

/// Windows `name` table language IDs to try, best first, for a UI locale.
/// Empty for English (nothing to localize) and for languages with no
/// conventional font localization here.
List<int> windowsFontLangIds(String language, String? country) {
  final c = (country ?? '').toUpperCase();
  switch (language.toLowerCase()) {
    case 'zh':
      // Traditional-script regions share glyph names; try the exact region
      // first, then the other traditional ones, then simplified as a last
      // resort (a font may only carry one Chinese name).
      if (c == 'TW' || c == 'HK' || c == 'MO' || c == 'HANT' || c == '') {
        return const [0x0404, 0x0C04, 0x1404, 0x0804, 0x1004];
      }
      return const [0x0804, 0x1004, 0x0404, 0x0C04, 0x1404];
    case 'ja':
      return const [0x0411];
    case 'ko':
      return const [0x0412];
    case 'ar':
      return const [0x0401, 0x0801, 0x0C01, 0x1001, 0x3001];
    default:
      return const [];
  }
}

/// fontconfig language tags (as `%{familylang}` prints them) to try, best
/// first, for a UI locale. Empty for English.
List<String> fcFontLangs(String language, String? country) {
  final c = (country ?? '').toUpperCase();
  switch (language.toLowerCase()) {
    case 'zh':
      if (c == 'TW' || c == 'HK' || c == 'MO' || c == 'HANT' || c == '') {
        return const ['zh-tw', 'zh-hk', 'zh-mo', 'zh-hant', 'zh', 'zh-cn'];
      }
      return const ['zh-cn', 'zh-sg', 'zh-hans', 'zh', 'zh-tw'];
    case 'ja':
      return const ['ja'];
    case 'ko':
      return const ['ko'];
    case 'ar':
      return const ['ar'];
    default:
      return const [];
  }
}

String _key(String family) => family.trim().toLowerCase();

/// English family → localized family from parsed `name` tables (one map per
/// sub-font, see print_fonts.nameTableFamilies). Both the plain family
/// (name ID 1, what the Windows registry lists) and the typographic family
/// (ID 16) become keys; the localized value prefers the same ID, then the
/// other. Fonts without a name in any of [langIds] contribute nothing.
Map<String, String> localizedFamiliesFromNameTables(
  Iterable<Map<int, ({String? family, String? typographic})>> fonts,
  List<int> langIds,
) {
  final out = <String, String>{};
  for (final names in fonts) {
    // English source names: en-US, else any English variant, else the
    // first record — some fonts only carry 0x0409.
    var en = names[0x0409];
    if (en == null) {
      for (final e in names.entries) {
        if ((e.key & 0x3FF) == 0x09) {
          en = e.value;
          break;
        }
      }
    }
    if (en == null && names.isNotEmpty) en = names.values.first;
    if (en == null) continue;
    ({String? family, String? typographic})? loc;
    for (final id in langIds) {
      loc = names[id];
      if (loc != null) break;
    }
    if (loc == null) continue;
    final locFamily = loc.family ?? loc.typographic;
    final locTypo = loc.typographic ?? loc.family;
    if (en.family != null && locFamily != null && en.family != locFamily) {
      out.putIfAbsent(_key(en.family!), () => locFamily);
    }
    if (en.typographic != null &&
        locTypo != null &&
        en.typographic != locTypo) {
      out.putIfAbsent(_key(en.typographic!), () => locTypo);
    }
  }
  return out;
}

/// Parse `fc-list --format '%{family}|%{familylang}\n'` output: each line is
/// "MingLiU,細明體|en,zh-tw". The English entry (lang "en", else the first)
/// is the key; the first entry whose language is in [langs] (best first)
/// the value.
Map<String, String> parseFcListLocalized(String output, List<String> langs) {
  final out = <String, String>{};
  for (final raw in output.split('\n')) {
    final line = raw.trim();
    final bar = line.lastIndexOf('|');
    if (bar <= 0) continue;
    final fams = line.substring(0, bar).split(',');
    final ls = line.substring(bar + 1).split(',');
    if (fams.isEmpty || fams.length != ls.length) continue;
    String? en;
    for (var i = 0; i < fams.length; i++) {
      final l = ls[i].trim().toLowerCase();
      if (l == 'en' || l.startsWith('en-')) {
        en = fams[i].trim();
        break;
      }
    }
    en ??= fams.first.trim();
    if (en.isEmpty) continue;
    String? loc;
    for (final want in langs) {
      for (var i = 0; i < fams.length; i++) {
        if (ls[i].trim().toLowerCase() == want) {
          loc = fams[i].trim();
          break;
        }
      }
      if (loc != null) break;
    }
    if (loc == null || loc.isEmpty || loc == en) continue;
    out.putIfAbsent(_key(en), () => loc!);
  }
  return out;
}

final Map<String, Map<String, String>> _cache = {};

/// English family (lower-cased key) → localized display name for the UI
/// locale [language]/[country]. Empty when nothing is localized (English UI,
/// no data, unsupported platform). One enumeration per locale per process.
Future<Map<String, String>> localizedFontFamilyNames(
  String language,
  String? country,
) async {
  final ck = '$language|${country ?? ''}';
  final hit = _cache[ck];
  if (hit != null) return hit;
  var out = <String, String>{};
  final sw = Stopwatch()..start();
  try {
    if (Platform.isWindows) {
      final langIds = windowsFontLangIds(language, country);
      if (langIds.isNotEmpty) {
        final reg = await windowsFontRegistry();
        final files = reg.values.toSet();
        final tables = <Map<int, ({String? family, String? typographic})>>[];
        for (final f in files) {
          for (final t in await readFontNameTables(f)) {
            tables.add(nameTableFamilies(t));
          }
        }
        out = localizedFamiliesFromNameTables(tables, langIds);
        fontNamesLog?.call(
          'font names: ${files.length} files, ${tables.length} faces, '
          '${out.length} localized ($ck) in ${sw.elapsedMilliseconds} ms',
        );
      }
    } else if (Platform.isLinux) {
      final langs = fcFontLangs(language, country);
      if (langs.isNotEmpty) {
        final r = await Process.run('fc-list', [
          '--format',
          '%{family}|%{familylang}\n',
        ]);
        if (r.exitCode == 0) {
          out = parseFcListLocalized(r.stdout as String, langs);
        }
        fontNamesLog?.call(
          'font names: ${out.length} localized ($ck) in '
          '${sw.elapsedMilliseconds} ms (fc-list)',
        );
      }
    } else if (Platform.isMacOS) {
      if (language.toLowerCase() != 'en') {
        // CoreText follows the system languages; ffi off the UI isolate
        // (a few hundred CTFontCreateWithName calls).
        final map = await Isolate.run(() => macLocalizedFamilyNames());
        out = {
          for (final e in map.entries)
            if (e.value != e.key) _key(e.key): e.value,
        };
        fontNamesLog?.call(
          'font names: ${out.length} localized ($ck) in '
          '${sw.elapsedMilliseconds} ms (CoreText)',
        );
      }
    }
  } catch (e) {
    fontNamesLog?.call('font names: failed ($e)');
  }
  return _cache[ck] = out;
}

/// Test seam: drop the per-process cache.
void resetLocalizedFontNamesCache() => _cache.clear();

/// Display label for [family] given a localized map: the localized name, or
/// the family itself.
String fontDisplayName(Map<String, String> localized, String family) =>
    localized[_key(family)] ?? family;
