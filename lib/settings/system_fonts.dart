// System font family enumeration. Pure Dart: Windows reads the fonts registry
// (through PowerShell with forced UTF-8 output so CJK names survive the
// console codepage), Linux asks fc-list, macOS calls CoreText through
// dart:ffi (util/mac_fonts.dart). Parsing lives in pure functions so it stays
// headless-testable.

import 'dart:convert';
import 'dart:io';

import '../util/mac_fonts.dart';

/// Strip registry display-name suffixes like " (TrueType)" / " (OpenType)".
String stripFontSuffix(String name) => name
    .replaceAll(
      RegExp(r'\s*\((TrueType|OpenType)[^)]*\)\s*$', caseSensitive: false),
      '',
    )
    .trim();

const Set<String> _styleWords = {
  'bold', 'italic', 'oblique', 'light', 'semilight', 'medium', 'black',
  'thin', 'semibold', 'demibold', 'extrabold', 'extralight', 'ultralight',
  'heavy', 'condensed', 'semicondensed', 'narrow', 'expanded',
};

/// True for style-variant entries ("Arial Bold Italic") — those are not
/// usable as a Flutter fontFamily (the base family name is).
bool isFontStyleVariant(String name) {
  final tokens = name.toLowerCase().split(RegExp(r'[\s-]+'));
  return tokens.any(_styleWords.contains);
}

// PowerShell metadata properties that come along with the registry values.
const Set<String> _psMetaProps = {
  'PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider',
};

/// Parse "one font display name per line" output (the PowerShell registry
/// enumeration below): strip " (TrueType)" suffixes, split " & "-joined
/// multi-family values, drop style variants and PowerShell metadata rows.
List<String> parseFontNameLines(String output) {
  final out = <String>{};
  for (final rawLine in output.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || _psMetaProps.contains(line)) continue;
    final raw = stripFontSuffix(line);
    for (final part in raw.split(' & ')) {
      // "Cascadia Code Regular" → family "Cascadia Code".
      final name = part
          .replaceAll(RegExp(r'\s+Regular$', caseSensitive: false), '')
          .trim();
      if (name.isEmpty || isFontStyleVariant(name)) continue;
      out.add(name);
    }
  }
  return sortedFontList(out);
}

/// Parse `fc-list : family` output (one font per line, aliases separated by
/// commas — keep the first).
List<String> parseFcList(String output) {
  final out = <String>{};
  for (final line in output.split('\n')) {
    final name = line.split(',').first.trim();
    if (name.isEmpty || isFontStyleVariant(name)) continue;
    out.add(name);
  }
  return sortedFontList(out);
}

List<String> sortedFontList(Set<String> names) =>
    names.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

/// Enumerate installed font families. Failures (no reg/fc-list, unsupported
/// platform) yield an empty list rather than throwing.
Future<List<String>> listSystemFontFamilies() async {
  try {
    if (Platform.isWindows) {
      // PowerShell enumerates the Fonts value names one per line. Chosen over
      // `cmd /c reg query`: Dart's argument quoting (\" escapes) is not what
      // cmd expects, and reg.exe writes in the console codepage — here the
      // script only uses single quotes and forces UTF-8 output, so CJK
      // family names survive.
      const script =
          r"[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; "
          r"foreach ($h in 'HKLM','HKCU') { "
          r"$p = $h + ':\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'; "
          r"if (Test-Path $p) { (Get-ItemProperty $p).PSObject.Properties | "
          r"ForEach-Object { $_.Name } } }";
      final r = await Process.run(
        'powershell',
        ['-NoProfile', '-Command', script],
        stdoutEncoding: utf8,
      );
      if (r.exitCode == 0) return parseFontNameLines(r.stdout as String);
      return const [];
    }
    if (Platform.isMacOS) {
      // CoreText already hands back family names (no " (TrueType)" suffixes,
      // no style variants) — and unlike the other platforms a style word can
      // be part of a real family here ("Avenir Next Condensed"), so the
      // variant filter must NOT run over this list.
      return sortedFontList(macFontFamilies().toSet());
    }
    if (Platform.isLinux) {
      final r = await Process.run('fc-list', [':', 'family']);
      if (r.exitCode == 0) return parseFcList(r.stdout as String);
    }
  } catch (_) {}
  return const [];
}
