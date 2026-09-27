// macOS font family enumeration via dart:ffi (CoreText). Pure Dart, no
// flutter import, so it stays headless-testable like win_registry.dart.
//
// Why ffi and not a subprocess: `system_profiler SPFontsDataType` takes
// several seconds (it parses every font file) and fc-list is not installed by
// default — CTFontManagerCopyAvailableFontFamilyNames() answers in
// milliseconds and gives exactly the family names Flutter's fontFamily wants.
// Works under App Sandbox (font enumeration needs no entitlement).

import 'dart:ffi';

import 'package:ffi/ffi.dart';

const int _kCFStringEncodingUTF8 = 0x08000100;

DynamicLibrary _open(String framework) =>
    DynamicLibrary.open('/System/Library/Frameworks/'
        '$framework.framework/$framework');

final DynamicLibrary _coreText = _open('CoreText');
final DynamicLibrary _coreFoundation = _open('CoreFoundation');

// CFArrayRef CTFontManagerCopyAvailableFontFamilyNames(void)
final Pointer<Void> Function() _copyFamilyNames = _coreText.lookupFunction<
    Pointer<Void> Function(),
    Pointer<Void> Function()>('CTFontManagerCopyAvailableFontFamilyNames');

// CFIndex is a signed long (64-bit here).
final int Function(Pointer<Void>) _cfArrayGetCount =
    _coreFoundation.lookupFunction<Int64 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('CFArrayGetCount');

final Pointer<Void> Function(Pointer<Void>, int) _cfArrayGetValueAtIndex =
    _coreFoundation.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Int64),
        Pointer<Void> Function(Pointer<Void>, int)>('CFArrayGetValueAtIndex');

final int Function(Pointer<Void>) _cfStringGetLength =
    _coreFoundation.lookupFunction<Int64 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('CFStringGetLength');

// const char* CFStringGetCStringPtr(CFStringRef, CFStringEncoding) — fast
// path; returns NULL whenever the string is not already in that encoding.
final Pointer<Utf8> Function(Pointer<Void>, int) _cfStringGetCStringPtr =
    _coreFoundation.lookupFunction<
        Pointer<Utf8> Function(Pointer<Void>, Uint32),
        Pointer<Utf8> Function(Pointer<Void>, int)>('CFStringGetCStringPtr');

// Boolean CFStringGetCString(CFStringRef, char*, CFIndex, CFStringEncoding)
final int Function(Pointer<Void>, Pointer<Utf8>, int, int) _cfStringGetCString =
    _coreFoundation.lookupFunction<
        Uint8 Function(Pointer<Void>, Pointer<Utf8>, Int64, Uint32),
        int Function(Pointer<Void>, Pointer<Utf8>, int, int)>(
        'CFStringGetCString');

final void Function(Pointer<Void>) _cfRelease = _coreFoundation.lookupFunction<
    Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CFRelease');

/// System-internal families ('.SF NS Mono', '.AppleSystemUIFont') that the
/// text engine refuses to resolve by name — never offer them.
bool isHiddenMacFamily(String name) => name.startsWith('.');

String? _toDart(Pointer<Void> cfString) {
  final fast = _cfStringGetCStringPtr(cfString, _kCFStringEncodingUTF8);
  if (fast != nullptr) return fast.toDartString();
  // 4 bytes per UTF-16 unit covers the worst UTF-8 expansion, +1 for NUL.
  final cap = _cfStringGetLength(cfString) * 4 + 1;
  final buf = calloc<Uint8>(cap).cast<Utf8>();
  try {
    if (_cfStringGetCString(cfString, buf, cap, _kCFStringEncodingUTF8) == 0) {
      return null;
    }
    return buf.toDartString();
  } finally {
    calloc.free(buf);
  }
}

// CFStringRef CFStringCreateWithCString(CFAllocatorRef, const char*, CFStringEncoding)
final Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, int)
_cfStringCreateWithCString = _coreFoundation.lookupFunction<
    Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Uint32),
    Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, int)>(
    'CFStringCreateWithCString');

// CTFontRef CTFontCreateWithName(CFStringRef name, CGFloat size, const CGAffineTransform*)
final Pointer<Void> Function(Pointer<Void>, double, Pointer<Void>)
_ctFontCreateWithName = _coreText.lookupFunction<
    Pointer<Void> Function(Pointer<Void>, Double, Pointer<Void>),
    Pointer<Void> Function(Pointer<Void>, double, Pointer<Void>)>(
    'CTFontCreateWithName');

// CFStringRef CTFontCopyLocalizedName(CTFontRef, CFStringRef nameKey, CFStringRef* actualLanguage)
final Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)
_ctFontCopyLocalizedName = _coreText.lookupFunction<
    Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>),
    Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)>(
    'CTFontCopyLocalizedName');

// const CFStringRef kCTFontFamilyNameKey — an exported constant, so the
// symbol is a pointer to the CFStringRef.
final Pointer<Void> _kCTFontFamilyNameKey =
    _coreText.lookup<Pointer<Void>>('kCTFontFamilyNameKey').value;

/// Family name localized for the user's preferred languages (what Font Book
/// shows): "細明體" for MingLiU on a Traditional-Chinese system. The canonical
/// name itself when CoreText has no localized entry; null when the family
/// cannot be resolved.
String? macLocalizedFamilyName(String family) {
  final cName = family.toNativeUtf8();
  Pointer<Void> cf = nullptr, font = nullptr, loc = nullptr;
  try {
    cf = _cfStringCreateWithCString(nullptr, cName, _kCFStringEncodingUTF8);
    if (cf == nullptr) return null;
    font = _ctFontCreateWithName(cf, 12.0, nullptr);
    if (font == nullptr) return null;
    loc = _ctFontCopyLocalizedName(font, _kCTFontFamilyNameKey, nullptr);
    if (loc == nullptr) return null;
    return _toDart(loc);
  } finally {
    if (loc != nullptr) _cfRelease(loc);
    if (font != nullptr) _cfRelease(font);
    if (cf != nullptr) _cfRelease(cf);
    calloc.free(cName);
  }
}

/// Canonical family → localized family for every installed family (only
/// the ones whose localized name differs are worth keeping; the caller
/// filters). Meant to run off the UI isolate: a few hundred CTFont creations.
Map<String, String> macLocalizedFamilyNames() {
  final out = <String, String>{};
  for (final f in macFontFamilies()) {
    final l = macLocalizedFamilyName(f);
    if (l != null && l.isNotEmpty) out[f] = l;
  }
  return out;
}

/// Installed font family names, unsorted. Empty if CoreText is unavailable.
List<String> macFontFamilies() {
  final array = _copyFamilyNames();
  if (array == nullptr) return const [];
  try {
    final out = <String>[];
    final n = _cfArrayGetCount(array);
    for (var i = 0; i < n; i++) {
      final name = _toDart(_cfArrayGetValueAtIndex(array, i));
      if (name == null || name.isEmpty || isHiddenMacFamily(name)) continue;
      out.add(name);
    }
    return out;
  } finally {
    _cfRelease(array);
  }
}
