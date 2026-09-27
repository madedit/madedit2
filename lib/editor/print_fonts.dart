// Print fonts from the system (pure Dart: dart:io + dart:typed_data, no
// flutter; tool/print_fonts_test.dart). Nothing is bundled with the app.
//
// package:pdf can only embed glyf-flavoured TrueType (no CFF/OpenType
// outlines, no .ttc collections), while the CJK fonts on Windows are all
// .ttc (msjh.ttc, mingliu.ttc, msyh.ttc, meiryo.ttc…) and Noto Sans CJK is
// CFF. So this file
//   • splits a sub-font out of a TrueType collection into a standalone sfnt
//     (extractTtcFont) — the tables are shared, only the directory is rebuilt;
//   • checks that a font is something package:pdf can subset (ttfEmbeddable);
//   • finds font files by family name per platform: Windows via the Fonts
//     registry (name → file), Linux via fc-match, macOS via known paths.
// The caller (print_page.dart) falls back to raster printing when no usable
// font is found or the text has characters none of them cover.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Log hook (keeps this file flutter-free; the app wires Log into it).
void Function(String msg)? printFontLog;

void _log(String m) => printFontLog?.call(m);

// ── sfnt / TTC parsing ───────────────────────────────────────────────────

int _u32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
int _u16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];
String _tag(Uint8List b, int o) => String.fromCharCodes(b.sublist(o, o + 4));

const int _sfntTrueType = 0x00010000;
const int _sfntTrue = 0x74727565; // 'true' (older Mac TrueType)
const int _sfntTtcf = 0x74746366; // 'ttcf'
// 'OTTO' (0x4F54544F, CFF outlines) is simply "not one of the above".

bool isTtc(Uint8List b) => b.length >= 12 && _u32(b, 0) == _sfntTtcf;

int ttcFontCount(Uint8List b) => isTtc(b) ? _u32(b, 8) : 1;

/// Rebuild sub-font [index] of the collection [ttc] as a standalone font
/// file: a fresh offset table + table directory, table data copied over
/// (4-byte aligned). Table checksums are kept; `head.checkSumAdjustment`
/// goes stale, which no parser verifies.
Uint8List extractTtcFont(Uint8List ttc, int index) {
  if (!isTtc(ttc)) return ttc;
  final n = _u32(ttc, 8);
  if (index < 0 || index >= n) {
    throw RangeError('TTC has $n fonts, index $index');
  }
  final dir = _u32(ttc, 12 + index * 4);
  final numTables = _u16(ttc, dir + 4);
  final headerLen = 12 + numTables * 16;
  // Total size: header + each table padded to 4 bytes.
  var total = headerLen;
  for (var i = 0; i < numTables; i++) {
    final len = _u32(ttc, dir + 12 + i * 16 + 12);
    total += (len + 3) & ~3;
  }
  final out = Uint8List(total);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, _u32(ttc, dir)); // sfnt version of the sub-font
  bd.setUint16(4, numTables);
  var maxPow2 = 1, log2 = 0;
  while (maxPow2 * 2 <= numTables) {
    maxPow2 *= 2;
    log2++;
  }
  bd.setUint16(6, maxPow2 * 16);
  bd.setUint16(8, log2);
  bd.setUint16(10, numTables * 16 - maxPow2 * 16);
  var dataPos = headerLen;
  for (var i = 0; i < numTables; i++) {
    final rec = dir + 12 + i * 16;
    final off = _u32(ttc, rec + 8), len = _u32(ttc, rec + 12);
    final o = 12 + i * 16;
    out.setRange(o, o + 4, ttc, rec); // tag
    bd.setUint32(o + 4, _u32(ttc, rec + 4)); // checksum
    bd.setUint32(o + 8, dataPos);
    bd.setUint32(o + 12, len);
    out.setRange(dataPos, dataPos + len, ttc, off);
    dataPos += (len + 3) & ~3;
  }
  return out;
}

/// Table directory of a standalone sfnt: tag → (offset, length).
Map<String, (int, int)> _tables(Uint8List b) {
  final out = <String, (int, int)>{};
  if (b.length < 12) return out;
  final n = _u16(b, 4);
  for (var i = 0; i < n; i++) {
    final rec = 12 + i * 16;
    if (rec + 16 > b.length) break;
    out[_tag(b, rec)] = (_u32(b, rec + 8), _u32(b, rec + 12));
  }
  return out;
}

/// Can package:pdf subset and embed this (standalone) font? TrueType glyf
/// outlines with the tables its parser insists on; CFF ('OTTO') and
/// collections are rejected (split a collection with [extractTtcFont] first).
bool ttfEmbeddable(Uint8List b) {
  if (b.length < 12) return false;
  final v = _u32(b, 0);
  if (v != _sfntTrueType && v != _sfntTrue) return false; // OTTO / ttcf / junk
  final t = _tables(b);
  for (final need in ['glyf', 'loca', 'cmap', 'hmtx', 'hhea', 'head', 'maxp']) {
    if (!t.containsKey(need)) return false;
  }
  return true;
}

/// Family name from the `name` table (typographic family 16 if present, else
/// family 1; Windows/Unicode records first, Mac Roman as a fallback). Null
/// when the table is missing or unreadable.
String? ttfFamilyName(Uint8List b) {
  final t = _tables(b)['name'];
  if (t == null) return null;
  final base = t.$1;
  if (base + 6 > b.length) return null;
  final count = _u16(b, base + 2), strBase = base + _u16(b, base + 4);
  String? best;
  var bestScore = -1;
  for (var i = 0; i < count; i++) {
    final r = base + 6 + i * 12;
    if (r + 12 > b.length) break;
    final plat = _u16(b, r), enc = _u16(b, r + 2), lang = _u16(b, r + 4);
    final id = _u16(b, r + 6), len = _u16(b, r + 8), off = _u16(b, r + 10);
    if (id != 1 && id != 16) continue;
    final s = strBase + off;
    if (s + len > b.length) continue;
    String text;
    int score;
    if (plat == 3 && (enc == 1 || enc == 10)) {
      final cu = <int>[];
      for (var k = 0; k + 1 < len; k += 2) {
        cu.add(_u16(b, s + k));
      }
      text = String.fromCharCodes(cu);
      score = (id == 16 ? 20 : 10) + (lang == 0x409 ? 2 : 0);
    } else if (plat == 1 && enc == 0) {
      text = latin1.decode(b.sublist(s, s + len));
      score = id == 16 ? 5 : 1;
    } else {
      continue;
    }
    if (text.isEmpty) continue;
    if (score > bestScore) {
      best = text;
      bestScore = score;
    }
  }
  return best;
}

/// Family names of one `name` table (the table's own bytes, not a whole
/// font), per Windows-platform language ID: lang → (family = name ID 1,
/// typographic = name ID 16). Feeds the font dialog's localized display
/// names (settings/font_display_names.dart): MingLiU's table carries both
/// 0x409 "MingLiU" and 0x404 "細明體".
Map<int, ({String? family, String? typographic})> nameTableFamilies(
  Uint8List t,
) {
  final out = <int, ({String? family, String? typographic})>{};
  if (t.length < 6) return out;
  final count = _u16(t, 2), strBase = _u16(t, 4);
  for (var i = 0; i < count; i++) {
    final r = 6 + i * 12;
    if (r + 12 > t.length) break;
    final plat = _u16(t, r), enc = _u16(t, r + 2), lang = _u16(t, r + 4);
    final id = _u16(t, r + 6), len = _u16(t, r + 8), off = _u16(t, r + 10);
    if (id != 1 && id != 16) continue;
    if (plat != 3 || (enc != 1 && enc != 10)) continue; // Windows Unicode
    final s = strBase + off;
    if (s + len > t.length) continue;
    final cu = <int>[];
    for (var k = 0; k + 1 < len; k += 2) {
      cu.add(_u16(t, s + k));
    }
    final text = String.fromCharCodes(cu).trim();
    if (text.isEmpty) continue;
    final cur = out[lang] ?? (family: null, typographic: null);
    out[lang] = id == 1
        ? (family: text, typographic: cur.typographic)
        : (family: cur.family, typographic: text);
  }
  return out;
}

/// The `name` table bytes of every sub-font in the file at [path] (one for a
/// standalone font), read with three small seeks per sub-font instead of the
/// whole file — CJK collections run to tens of MB and the dialog walks a few
/// hundred files. Empty on any read/parse problem.
Future<List<Uint8List>> readFontNameTables(String path) async {
  RandomAccessFile f;
  try {
    f = await File(path).open();
  } catch (_) {
    return const [];
  }
  try {
    final len = await f.length();
    Future<Uint8List?> read(int off, int n) async {
      if (off < 0 || n <= 0 || off + n > len) return null;
      await f.setPosition(off);
      final b = await f.read(n);
      return b.length == n ? b : null;
    }

    final head = await read(0, 12);
    if (head == null) return const [];
    final offsets = <int>[];
    if (_u32(head, 0) == _sfntTtcf) {
      final n = _u32(head, 8);
      if (n <= 0 || n > 64) return const [];
      final dirs = await read(12, n * 4);
      if (dirs == null) return const [];
      for (var i = 0; i < n; i++) {
        offsets.add(_u32(dirs, i * 4));
      }
    } else {
      offsets.add(0);
    }
    final out = <Uint8List>[];
    for (final o in offsets) {
      final h = await read(o, 12);
      if (h == null) continue;
      final numTables = _u16(h, 4);
      if (numTables == 0 || numTables > 512) continue;
      final dir = await read(o + 12, numTables * 16);
      if (dir == null) continue;
      for (var i = 0; i < numTables; i++) {
        final rec = i * 16;
        if (_tag(dir, rec) != 'name') continue;
        final t = await read(_u32(dir, rec + 8), _u32(dir, rec + 12));
        if (t != null) out.add(t);
        break;
      }
    }
    return out;
  } catch (_) {
    return const [];
  } finally {
    await f.close();
  }
}

/// Load an embeddable font from [path]. For a collection, [family] picks the
/// sub-font by its `name` table (else [index]). Null when the file is missing
/// or not something package:pdf can embed.
Future<Uint8List?> loadEmbeddableFont(
  String path, {
  int index = 0,
  String? family,
}) async {
  final f = File(path);
  if (!await f.exists()) return null;
  Uint8List bytes;
  try {
    bytes = await f.readAsBytes();
  } catch (e) {
    _log('print font: cannot read $path ($e)');
    return null;
  }
  if (isTtc(bytes)) {
    final n = ttcFontCount(bytes);
    var pick = index.clamp(0, n - 1);
    if (family != null) {
      for (var i = 0; i < n; i++) {
        final sub = extractTtcFont(bytes, i);
        if (_sameFamily(ttfFamilyName(sub), family)) {
          pick = i;
          break;
        }
      }
    }
    bytes = extractTtcFont(bytes, pick);
  }
  if (!ttfEmbeddable(bytes)) {
    _log('print font: $path is not embeddable TrueType (CFF/other)');
    return null;
  }
  return bytes;
}

bool _sameFamily(String? a, String b) =>
    a != null && a.trim().toLowerCase() == b.trim().toLowerCase();

// ── Windows: Fonts registry ──────────────────────────────────────────────

Map<String, String>? _winFontsCache;

/// `registry value name → file` for HKLM+HKCU …\Fonts (relative files live
/// in %WINDIR%\Fonts). One PowerShell run per process (1–3 s cold), cached.
Future<Map<String, String>> windowsFontRegistry() async {
  final cached = _winFontsCache;
  if (cached != null) return cached;
  final out = <String, String>{};
  if (Platform.isWindows) {
    // Same constraints as system_fonts.dart: single quotes only, force UTF-8.
    const script =
        r"[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; "
        r"foreach ($h in 'HKLM','HKCU') { "
        r"$p = $h + ':\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'; "
        r"if (Test-Path $p) { (Get-ItemProperty $p).PSObject.Properties | "
        r"Where-Object { $_.Value -is [string] } | "
        r"ForEach-Object { $_.Name + '|' + $_.Value } } }";
    try {
      final r = await Process.run(
        'powershell',
        ['-NoProfile', '-Command', script],
        stdoutEncoding: utf8,
      );
      if (r.exitCode == 0) {
        final fontsDir =
            '${Platform.environment['WINDIR'] ?? r'C:\Windows'}\\Fonts\\';
        for (final line in const LineSplitter().convert(r.stdout as String)) {
          final i = line.lastIndexOf('|');
          if (i <= 0) continue;
          final name = line.substring(0, i).trim();
          var file = line.substring(i + 1).trim();
          if (file.isEmpty || name.startsWith('PS')) continue;
          if (!file.contains('\\') && !file.contains('/')) file = fontsDir + file;
          out[name] = file;
        }
      }
    } catch (e) {
      _log('print font: registry query failed ($e)');
    }
  }
  return _winFontsCache = out;
}

/// Families listed by one registry value name: "Microsoft JhengHei &
/// Microsoft JhengHei UI (TrueType)" → [Microsoft JhengHei, Microsoft
/// JhengHei UI]. Style words are kept ("Consolas Bold" is not "Consolas").
List<String> windowsRegistryFamilies(String valueName) {
  var s = valueName.trim();
  s = s.replaceAll(RegExp(r'\s*\((TrueType|OpenType)\)\s*$', caseSensitive: false), '');
  return [for (final p in s.split('&')) p.trim()].where((p) => p.isNotEmpty).toList();
}

/// Font file for [family] from the registry map (exact family, then
/// "family Regular"); null when not installed.
String? windowsFontFileFor(Map<String, String> registry, String family) {
  final want = family.trim().toLowerCase();
  if (want.isEmpty) return null;
  String? regular;
  for (final e in registry.entries) {
    for (final f in windowsRegistryFamilies(e.key)) {
      final n = f.toLowerCase();
      if (n == want) return e.value;
      if (n == '$want regular') regular ??= e.value;
    }
  }
  return regular;
}

// ── Linux: fc-match ──────────────────────────────────────────────────────

/// fc-match [pattern] → (file, index, family); null when fc-match is
/// missing. fc-match always returns *something* — the caller decides
/// whether the family it got is acceptable.
Future<(String, int, String)?> fcMatch(String pattern) async {
  try {
    final r = await Process.run('fc-match', [
      '-f',
      '%{file}|%{index}|%{family}',
      pattern,
    ]);
    if (r.exitCode != 0) return null;
    final parts = (r.stdout as String).trim().split('|');
    if (parts.length < 3 || parts[0].isEmpty) return null;
    return (parts[0], int.tryParse(parts[1]) ?? 0, parts[2].split(',').first);
  } catch (_) {
    return null;
  }
}

// ── Candidates per platform ──────────────────────────────────────────────

/// Latin (monospace) families to try after the editor's own font.
List<String> latinFallbackFamilies() => Platform.isWindows
    ? const ['Consolas', 'Cascadia Mono', 'Courier New', 'Lucida Console']
    : Platform.isMacOS
    ? const ['Menlo', 'Monaco', 'Courier New']
    : const ['DejaVu Sans Mono', 'Liberation Mono', 'Noto Sans Mono', 'monospace'];

/// CJK families per locale key ('tc' / 'sc' / 'j'), best first. Only
/// TrueType-outline fonts can work; CFF ones (Noto CJK, PingFang, Hiragino)
/// are listed anyway and rejected at load time — harmless, and future
/// TrueType builds of them would just start working.
Map<String, List<String>> cjkFamilies() => Platform.isWindows
    ? const {
        'tc': ['Microsoft JhengHei', 'MingLiU', 'PMingLiU'],
        'sc': ['Microsoft YaHei', 'SimSun', 'NSimSun'],
        'j': ['Meiryo', 'Yu Gothic', 'MS Gothic', 'MS Mincho'],
      }
    : Platform.isMacOS
    ? const {
        'tc': ['Songti TC', 'Heiti TC', 'Arial Unicode MS'],
        'sc': ['Songti SC', 'Heiti SC', 'Arial Unicode MS'],
        'j': ['Arial Unicode MS', 'Hiragino Sans'],
      }
    : const {
        'tc': ['WenQuanYi Zen Hei', 'WenQuanYi Micro Hei', 'AR PL UMing TW', 'Droid Sans Fallback', 'Noto Sans CJK TC'],
        'sc': ['WenQuanYi Zen Hei', 'WenQuanYi Micro Hei', 'AR PL UMing CN', 'Droid Sans Fallback', 'Noto Sans CJK SC'],
        'j': ['Droid Sans Fallback', 'WenQuanYi Zen Hei', 'Noto Sans CJK JP'],
      };

// macOS has no fc-match: known files by family (a .ttc picks the sub-font
// by family name at load time).
const Map<String, String> _macFontFiles = {
  'Menlo': '/System/Library/Fonts/Menlo.ttc',
  'Monaco': '/System/Library/Fonts/Monaco.ttf',
  'Courier New': '/System/Library/Fonts/Supplemental/Courier New.ttf',
  'Songti TC': '/System/Library/Fonts/Supplemental/Songti.ttc',
  'Songti SC': '/System/Library/Fonts/Supplemental/Songti.ttc',
  'Heiti TC': '/System/Library/Fonts/STHeiti Medium.ttc',
  'Heiti SC': '/System/Library/Fonts/STHeiti Medium.ttc',
  'Arial Unicode MS': '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
  'Hiragino Sans': '/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc',
};

/// Resolve [family] to embeddable font bytes on this platform, or null.
Future<Uint8List?> loadSystemFontFamily(String family) async {
  if (family.trim().isEmpty) return null;
  if (Platform.isWindows) {
    final reg = await windowsFontRegistry();
    final file = windowsFontFileFor(reg, family);
    if (file == null) return null;
    return loadEmbeddableFont(file, family: family);
  }
  if (Platform.isMacOS) {
    String? file = _macFontFiles[family];
    if (file == null) {
      for (final e in _macFontFiles.entries) {
        if (e.key.toLowerCase() == family.toLowerCase()) {
          file = e.value;
          break;
        }
      }
    }
    if (file == null) {
      // User-installed fonts: try the conventional file names.
      for (final dir in [
        '${Platform.environment['HOME'] ?? ''}/Library/Fonts',
        '/Library/Fonts',
      ]) {
        for (final ext in ['ttf', 'ttc']) {
          final b = await loadEmbeddableFont('$dir/$family.$ext', family: family);
          if (b != null) return b;
          final b2 = await loadEmbeddableFont(
            '$dir/${family.replaceAll(' ', '')}.$ext',
            family: family,
          );
          if (b2 != null) return b2;
        }
      }
      return null;
    }
    return loadEmbeddableFont(file, family: family);
  }
  // Linux (and anything else with fontconfig).
  final m = await fcMatch(family);
  if (m == null) return null;
  final (file, index, got) = m;
  // fc-match substitutes freely; only accept a real match for a named
  // family (generic aliases like "monospace" take whatever comes back).
  final generic = const {'monospace', 'sans-serif', 'serif'}.contains(family);
  if (!generic && !_sameFamily(got, family)) return null;
  return loadEmbeddableFont(file, index: index);
}

/// The fonts to embed, primary first: the editor's family (or the first
/// Latin fallback that exists), then one CJK font per locale key in
/// [cjkOrder] (the UI locale's first). Null when not even a Latin font
/// could be found — the caller prints raster instead.
Future<List<Uint8List>?> resolvePrintFonts({
  required String editorFamily,
  required List<String> cjkOrder,
}) async {
  final out = <Uint8List>[];
  for (final fam in [editorFamily, ...latinFallbackFamilies()]) {
    final b = await loadSystemFontFamily(fam);
    if (b != null) {
      _log('print font: primary "$fam"');
      out.add(b);
      break;
    }
  }
  if (out.isEmpty) {
    _log('print font: no embeddable Latin font found');
    return null;
  }
  final byKey = cjkFamilies();
  if (Platform.isLinux) {
    // fontconfig knows which installed font covers a language.
    for (final key in cjkOrder) {
      final lang = key == 'j' ? 'ja' : (key == 'sc' ? 'zh-cn' : 'zh-tw');
      final m = await fcMatch(':lang=$lang');
      if (m == null) continue;
      final b = await loadEmbeddableFont(m.$1, index: m.$2);
      if (b != null) {
        _log('print font: cjk $key "${m.$3}" (fc-match)');
        out.add(b);
      }
    }
  }
  for (final key in cjkOrder) {
    for (final fam in byKey[key] ?? const <String>[]) {
      final b = await loadSystemFontFamily(fam);
      if (b != null) {
        _log('print font: cjk $key "$fam"');
        out.add(b);
        break;
      }
    }
  }
  return out;
}
