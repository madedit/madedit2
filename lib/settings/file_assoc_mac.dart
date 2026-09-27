// macOS file associations (Settings → File Associations…).
//
// The work happens natively in MacFilesPlugin (channel `madedit2/mac_files`,
// methods assocQuery / assocSet) through NSWorkspace:
//   - query:  urlForApplication(toOpen: UTType) -> handler bundle id
//   - set:    setDefaultApplication(at: ourBundle, toOpen: UTType)
//
// It deliberately does NOT use the older LaunchServices C API
// (LSSetDefaultRoleHandlerForContentType / LSCopyDefaultRoleHandlerForContentType)
// that this file used to call through dart:ffi: on current macOS those return
// noErr while changing nothing, and a read straight after a write still yields
// the old handler — the dialog could neither apply a change nor verify one.
// NSWorkspace applies immediately and reports real errors (sandbox included).
//
// This file stays flutter-free so file_assoc.dart remains headless-testable:
// the channel calls arrive as hooks, wired by the dialog (file_assoc_page.dart)
// exactly like [assocLog]. Unwired (headless, tests) every call reports
// "unsupported" rather than throwing.

import 'dart:io';

const String macBundleId = 'com.madedit.madedit2';

/// Set by the dialog to [MacFiles.assocQuery]: extension -> handler bundle id,
/// plus `<ext>.uti` -> UTI. Extensions nothing handles are absent.
Future<Map<String, String>> Function(List<String> exts)? macAssocQueryHook;

/// Set by the dialog to [MacFiles.assocSet]: returns `{ext: error}` for the
/// extensions that could not be applied (empty = all good).
Future<Map<String, String>> Function(List<String> exts)? macAssocSetHook;

/// Whether the native side is wired up (macOS with the plugin registered).
bool get macAssocSupported =>
    Platform.isMacOS && macAssocQueryHook != null && macAssocSetHook != null;

/// Extensions from [exts] that madedit2 is currently the default handler for.
Future<Set<String>> macOwnedExts(Iterable<String> exts) async {
  final hook = macAssocQueryHook;
  if (hook == null) return {};
  final list = exts.toList();
  final map = await hook(list);
  return {
    for (final e in list)
      if (map[e]?.toLowerCase() == macBundleId.toLowerCase()) e,
  };
}

/// The UTI an extension maps to, e.g. `txt` -> `public.plain-text`; null when
/// the query is unavailable. A `dyn.…` result means no installed app declares
/// the extension — LaunchServices will not bind a handler to such a type.
Future<String?> macUtiFor(String ext) async {
  final hook = macAssocQueryHook;
  if (hook == null) return null;
  return (await hook([ext]))['$ext.uti'];
}

/// Whether [uti] is a dynamically synthesised type (no app declares it).
bool macIsDynamicUti(String? uti) => uti != null && uti.startsWith('dyn.');

/// Make madedit2 the default handler for [exts]; returns `{ext: error}` for
/// the ones that failed (empty = all applied).
Future<Map<String, String>> macSetDefaultHandlers(Iterable<String> exts) async {
  final hook = macAssocSetHook;
  if (hook == null) {
    return {for (final e in exts) e: 'LaunchServices unavailable'};
  }
  if (exts.isEmpty) return {};
  return hook(exts.toList());
}
