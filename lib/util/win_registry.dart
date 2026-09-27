// Minimal Windows registry access via dart:ffi (advapi32) + SHChangeNotify
// (shell32) — just what the file-association feature needs, not a general
// wrapper. Exists because the previous PowerShell route (-EncodedCommand)
// made opening the dialog take seconds: powershell.exe cold start alone is
// 1–3 s, and per-key Get-ItemProperty over hundreds of `.ext` keys added
// more. Direct API calls do the same work in milliseconds — and key names
// like `*` are plain literals here (no provider globbing to dodge).
//
// Every helper opens/creates the key, does one thing, and closes it again.
// Pure Dart + dart:ffi/package:ffi (no flutter import): headless-testable
// against a scratch key (tool/file_assoc_test.dart uses
// HKCU\Software\madedit2_test_*, never the real Classes tree).

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// HKEY_CURRENT_USER.
const int hkeyCurrentUser = 0x80000001;

const int _keyRead = 0x20019; // KEY_READ
const int _keyWrite = 0x20006; // KEY_WRITE
const int _regSz = 1; // REG_SZ
const int _ok = 0; // ERROR_SUCCESS
const int _noMoreItems = 259; // ERROR_NO_MORE_ITEMS

final DynamicLibrary _advapi32 = DynamicLibrary.open('advapi32.dll');
final DynamicLibrary _shell32 = DynamicLibrary.open('shell32.dll');

final int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>) _regOpen =
    _advapi32
        .lookupFunction<
          Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<IntPtr>),
          int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)
        >('RegOpenKeyExW');

final int Function(
  int,
  Pointer<Utf16>,
  int,
  Pointer<Utf16>,
  int,
  int,
  Pointer<Void>,
  Pointer<IntPtr>,
  Pointer<Uint32>,
)
_regCreate = _advapi32
    .lookupFunction<
      Int32 Function(
        IntPtr,
        Pointer<Utf16>,
        Uint32,
        Pointer<Utf16>,
        Uint32,
        Uint32,
        Pointer<Void>,
        Pointer<IntPtr>,
        Pointer<Uint32>,
      ),
      int Function(
        int,
        Pointer<Utf16>,
        int,
        Pointer<Utf16>,
        int,
        int,
        Pointer<Void>,
        Pointer<IntPtr>,
        Pointer<Uint32>,
      )
    >('RegCreateKeyExW');

final int Function(
  int,
  int,
  Pointer<Utf16>,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Utf16>,
  Pointer<Uint32>,
  Pointer<Void>,
)
_regEnumKey = _advapi32
    .lookupFunction<
      Int32 Function(
        IntPtr,
        Uint32,
        Pointer<Utf16>,
        Pointer<Uint32>,
        Pointer<Uint32>,
        Pointer<Utf16>,
        Pointer<Uint32>,
        Pointer<Void>,
      ),
      int Function(
        int,
        int,
        Pointer<Utf16>,
        Pointer<Uint32>,
        Pointer<Uint32>,
        Pointer<Utf16>,
        Pointer<Uint32>,
        Pointer<Void>,
      )
    >('RegEnumKeyExW');

final int Function(
  int,
  Pointer<Utf16>,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Void>,
  Pointer<Uint32>,
)
_regQueryValue = _advapi32
    .lookupFunction<
      Int32 Function(
        IntPtr,
        Pointer<Utf16>,
        Pointer<Uint32>,
        Pointer<Uint32>,
        Pointer<Void>,
        Pointer<Uint32>,
      ),
      int Function(
        int,
        Pointer<Utf16>,
        Pointer<Uint32>,
        Pointer<Uint32>,
        Pointer<Void>,
        Pointer<Uint32>,
      )
    >('RegQueryValueExW');

final int Function(int, Pointer<Utf16>, int, int, Pointer<Void>, int)
_regSetValue = _advapi32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32),
      int Function(int, Pointer<Utf16>, int, int, Pointer<Void>, int)
    >('RegSetValueExW');

final int Function(int, Pointer<Utf16>) _regDeleteValue = _advapi32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>),
      int Function(int, Pointer<Utf16>)
    >('RegDeleteValueW');

final int Function(int, Pointer<Utf16>) _regDeleteTree = _advapi32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Utf16>),
      int Function(int, Pointer<Utf16>)
    >('RegDeleteTreeW');

final int Function(int) _regClose = _advapi32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('RegCloseKey');

final void Function(int, int, Pointer<Void>, Pointer<Void>) _shChangeNotify =
    _shell32
        .lookupFunction<
          Void Function(Int32, Uint32, Pointer<Void>, Pointer<Void>),
          void Function(int, int, Pointer<Void>, Pointer<Void>)
        >('SHChangeNotify');

// Run [f] with an open handle to root\path (null when it can't be opened).
R _withKey<R>(
  int root,
  String path,
  int access,
  R Function(int? hkey) f, {
  bool create = false,
}) {
  return using((arena) {
    final ph = arena<IntPtr>();
    final p = path.toNativeUtf16(allocator: arena);
    final int rc;
    if (create) {
      rc = _regCreate(root, p, 0, nullptr, 0, access, nullptr, ph, nullptr);
    } else {
      rc = _regOpen(root, p, 0, access, ph);
    }
    if (rc != _ok) return f(null);
    try {
      return f(ph.value);
    } finally {
      _regClose(ph.value);
    }
  });
}

/// Whether the key exists.
bool regKeyExists(int root, String path) =>
    _withKey(root, path, _keyRead, (h) => h != null);

/// Names of the direct subkeys (empty when the key can't be opened).
List<String> regEnumSubKeys(int root, String path) =>
    _withKey(root, path, _keyRead, (h) {
      if (h == null) return const <String>[];
      return using((arena) {
        const cap = 300; // max registry key name is 255 chars
        final buf = arena<Uint16>(cap).cast<Utf16>();
        final cch = arena<Uint32>();
        final out = <String>[];
        for (var i = 0; ; i++) {
          cch.value = cap;
          final rc =
              _regEnumKey(h, i, buf, cch, nullptr, nullptr, nullptr, nullptr);
          if (rc == _noMoreItems) break;
          if (rc != _ok) break; // skip oddities rather than loop forever
          out.add(buf.toDartString(length: cch.value));
        }
        return out;
      });
    });

/// Whether the named value exists on the key.
bool regValueExists(int root, String path, String name) =>
    _withKey(root, path, _keyRead, (h) {
      if (h == null) return false;
      return using((arena) {
        final n = name.toNativeUtf16(allocator: arena);
        return _regQueryValue(h, n, nullptr, nullptr, nullptr, nullptr) == _ok;
      });
    });

/// Create the key (parents included) and set a REG_SZ value; [name] null =
/// the key's default value. Returns success.
bool regSetString(int root, String path, String? name, String value) =>
    _withKey(root, path, _keyWrite, create: true, (h) {
      if (h == null) return false;
      return using((arena) {
        final n = name == null
            ? nullptr.cast<Utf16>()
            : name.toNativeUtf16(allocator: arena);
        final v = value.toNativeUtf16(allocator: arena);
        final bytes = (value.length + 1) * 2; // UTF-16 incl. terminator
        return _regSetValue(h, n, 0, _regSz, v.cast(), bytes) == _ok;
      });
    });

/// Delete one value from the key (missing key/value counts as success).
bool regDeleteValue(int root, String path, String name) =>
    _withKey(root, path, _keyWrite, (h) {
      if (h == null) return true;
      return using((arena) {
        final rc = _regDeleteValue(h, name.toNativeUtf16(allocator: arena));
        return rc == _ok || rc == 2; // ERROR_FILE_NOT_FOUND
      });
    });

/// Delete the key and everything under it (missing key counts as success).
bool regDeleteTree(int root, String path) => using((arena) {
  final rc = _regDeleteTree(root, path.toNativeUtf16(allocator: arena));
  return rc == _ok || rc == 2; // ERROR_FILE_NOT_FOUND
});

/// Tell Explorer the file associations changed (SHCNE_ASSOCCHANGED).
void shChangeNotifyAssoc() =>
    _shChangeNotify(0x08000000, 0, nullptr, nullptr);
