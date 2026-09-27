// Atomic file replacement shared by the editor's save and replace-in-files
// (pure dart:io; the macOS sandbox path lives in mac_files.dart because it
// needs a platform channel).

import 'dart:io';

/// Move [tmp] over [dest]. POSIX renames straight over; Windows (where an
/// existing dest makes rename fail) falls back to "dest -> backup, tmp ->
/// dest, drop backup", restoring the backup if the second step fails.
Future<void> atomicReplaceFile(String tmp, String dest) async {
  await preservePosixMode(dest, tmp);
  try {
    await File(tmp).rename(dest);
    return;
  } catch (_) {
    // fall through to the backup swap
  }
  final bak = '$dest.bak~';
  final bakFile = File(bak);
  if (await bakFile.exists()) await bakFile.delete();
  await File(dest).rename(bak);
  try {
    await File(tmp).rename(dest);
    await bakFile.delete();
  } catch (e) {
    await bakFile.rename(dest); // restore
    rethrow;
  }
}

/// POSIX only: give [to] (the temp file about to be renamed over [from])
/// the permission bits of [from]. rename() keeps the temp file's own mode —
/// the default 0644 from openWrite — so saving `~/.ssh/config` (0600) made
/// it world-readable and saving a script dropped its +x. Dart has no chmod;
/// the bits come from stat and go through chmod(1). Best effort: a missing
/// [from] (new file) or a failing chmod leaves the default mode. Ownership
/// is not carried over (that needs root); hard links are broken by any
/// rename-based replace.
Future<void> preservePosixMode(String from, String to) async {
  if (Platform.isWindows) return;
  try {
    final st = await File(from).stat();
    if (st.type == FileSystemEntityType.notFound) return;
    final bits = st.mode & 0xFFF; // rwx for ugo + setuid/setgid/sticky
    await Process.run('chmod', [bits.toRadixString(8).padLeft(4, '0'), to]);
  } catch (_) {
    // best effort
  }
}
