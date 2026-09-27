// External commands (Run menu): run a shell command with Notepad++-style
// placeholders for the active file, optionally capturing its output into
// the shell's output panel. Saved commands live in settings/run_commands.json
// and appear in the Run menu (and can get shortcuts: run.command {name}).
//
// Pure Dart (headless-testable: tool/run_commands_test.dart).

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'encoding/codecs.dart';

import '../settings/settings_paths.dart';

class RunCommand {
  const RunCommand(this.name, this.command, {this.capture = true});
  final String name;
  final String command;

  /// Show stdout/stderr in the output panel (else fire and forget).
  final bool capture;

  Map<String, Object?> toJson() => {
    'name': name,
    'command': command,
    'capture': capture,
  };

  static RunCommand? fromJson(Object? v) {
    if (v is! Map) return null;
    final n = v['name'], c = v['command'];
    if (n is! String || n.isEmpty || c is! String || c.isEmpty) return null;
    return RunCommand(n, c, capture: v['capture'] != false);
  }
}

/// What the placeholders expand from.
class RunContext {
  const RunContext({
    this.path,
    this.currentWord = '',
    this.currentLine = '',
    this.selection = '',
    this.lineNumber = 0,
  });
  final String? path; // full path of the active file (null = untitled)
  final String currentWord;
  final String currentLine;
  final String selection;
  final int lineNumber; // 1-based
}

/// The placeholders, for the dialog's help text.
const List<(String, String)> runPlaceholders = [
  (r'$(FULL_CURRENT_PATH)', 'full path of the current file'),
  (r'$(CURRENT_DIRECTORY)', 'its directory'),
  (r'$(FILE_NAME)', 'file name with extension'),
  (r'$(NAME_PART)', 'file name without extension'),
  (r'$(EXT_PART)', 'extension without the dot'),
  (r'$(CURRENT_WORD)', 'selection, or the word at the caret'),
  (r'$(CURRENT_LINE)', 'text of the caret line'),
  (r'$(CURRENT_LINE_NUMBER)', '1-based line number of the caret'),
];

/// Whether [command] references [placeholder] (e.g. `$(CURRENT_LINE)`), so
/// the caller only reads from the document what the command will use — the
/// caret line of a 2 GB single-line file was read whole for every command.
bool usesRunPlaceholder(String command, String placeholder) =>
    command.contains(placeholder);

/// A document-derived value ($(CURRENT_WORD) from the selection,
/// $(CURRENT_LINE)) that could break out of the command the user wrote once
/// it is pasted in unquoted and handed to the shell: quotes, separators,
/// substitution, redirection, newlines (a `sh -c` runs each line). The shell
/// asks for confirmation before running such a command — quoting it
/// automatically would break every command the user already quoted.
bool shellRiskyValue(String v) =>
    RegExp(r'''[\r\n"'`$\\|&;<>(){}!^%]''').hasMatch(v);

/// Expand the placeholders in [command].
String expandRunPlaceholders(String command, RunContext ctx) {
  final p = ctx.path ?? '';
  final sep = p.contains('\\') ? '\\' : '/';
  final slash = p.lastIndexOf(sep);
  final dir = slash >= 0 ? p.substring(0, slash) : '';
  final name = slash >= 0 ? p.substring(slash + 1) : p;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot + 1) : '';
  final word = ctx.selection.isNotEmpty ? ctx.selection : ctx.currentWord;
  return command
      .replaceAll(r'$(FULL_CURRENT_PATH)', p)
      .replaceAll(r'$(CURRENT_DIRECTORY)', dir)
      .replaceAll(r'$(FILE_NAME)', name)
      .replaceAll(r'$(NAME_PART)', stem)
      .replaceAll(r'$(EXT_PART)', ext)
      .replaceAll(r'$(CURRENT_WORD)', word)
      .replaceAll(r'$(CURRENT_LINE)', ctx.currentLine)
      .replaceAll(r'$(CURRENT_LINE_NUMBER)', '${ctx.lineNumber}');
}

class RunResult {
  const RunResult(this.exitCode, this.output, {this.detached = false});
  final int exitCode;
  final String output;
  final bool detached;
}

const int runOutputMaxBytes = 1 << 20;

/// Console output is bytes in whatever the program chose: strict UTF-8 when
/// it decodes (git, python with UTF-8 IO, …), else the OEM code page
/// ([codePage]: 950 Big5, 936 GBK, 932 Shift-JIS, 949 EUC-KR, 1252…) —
/// what cmd built-ins (dir/type/echo) and most Windows console tools write.
/// `chcp 65001` cannot fix this from the GUI: the spawned cmd has no console
/// to set the code page on.
String decodeConsoleOutput(Uint8List bytes, {int codePage = 0}) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    // fall through
  }
  final name = codePageCodecName(codePage);
  final codec = name == null ? null : textCodecByName(name);
  if (codec != null) return codec.decode(bytes).text;
  return utf8.decode(bytes, allowMalformed: true);
}

/// Windows code page → registered [TextCodec.name]; null when unknown.
String? codePageCodecName(int cp) => switch (cp) {
  950 => 'Big5',
  936 => 'GBK',
  54936 => 'GB18030',
  932 => 'Shift-JIS',
  949 => 'EUC-KR',
  20932 || 51932 => 'EUC-JP',
  1250 => 'Windows-1250',
  1251 => 'Windows-1251',
  1252 || 850 || 437 => 'Windows-1252',
  1253 => 'Windows-1253',
  1254 => 'Windows-1254',
  1255 => 'Windows-1255',
  1256 => 'Windows-1256',
  1257 => 'Windows-1257',
  1258 => 'Windows-1258',
  874 => 'Windows-874',
  28591 => 'ISO-8859-1',
  65001 => 'UTF-8',
  _ => null,
};

/// The OEM code page console programs write in (kernel32 `GetOEMCP`); 0 off
/// Windows or when the call fails.
int windowsOemCodePage() {
  if (!Platform.isWindows) return 0;
  try {
    final k32 = DynamicLibrary.open('kernel32.dll');
    final getOemCp = k32.lookupFunction<Uint32 Function(), int Function()>(
      'GetOEMCP',
    );
    return getOemCp();
  } catch (_) {
    return 0;
  }
}

/// Run [expanded] through the platform shell. [capture] waits for it and
/// returns its combined output (capped); otherwise it is started detached.
Future<RunResult> runExternalCommand(
  String expanded, {
  required bool capture,
  String? workingDirectory,
}) async {
  final cwd =
      workingDirectory != null && Directory(workingDirectory).existsSync()
      ? workingDirectory
      : null;
  if (!capture) {
    await Process.start(
      expanded,
      const [],
      runInShell: true,
      workingDirectory: cwd,
      mode: ProcessStartMode.detached,
    );
    return const RunResult(0, '', detached: true);
  }
  final proc = await Process.start(
    expanded,
    const [],
    runInShell: true,
    workingDirectory: cwd,
  );
  // Collected as bytes: the encoding is only decided once everything is in
  // (a UTF-8 sequence split across two chunks must not look malformed).
  final buf = BytesBuilder(copy: false);
  var truncated = false;
  void take(List<int> chunk) {
    if (truncated) return;
    final room = runOutputMaxBytes - buf.length;
    if (chunk.length >= room) {
      buf.add(chunk.sublist(0, room));
      truncated = true;
    } else {
      buf.add(chunk);
    }
  }

  final outDone = proc.stdout.forEach(take);
  final errDone = proc.stderr.forEach(take);
  final code = await proc.exitCode;
  await outDone;
  await errDone;
  final out = decodeConsoleOutput(
    buf.takeBytes(),
    codePage: windowsOemCodePage(),
  );
  return RunResult(code, truncated ? '$out\n[output truncated]' : out);
}

/// settings/run_commands.json.
class RunStore {
  RunStore([String? path]) : _path = path;
  final String? _path;
  String get path => _path ?? settingsPath('run_commands.json');

  Future<List<RunCommand>> load() async {
    try {
      final f = File(path);
      if (!await f.exists()) return const [];
      final j = jsonDecode(await f.readAsString());
      final list = j is Map ? j['commands'] : j;
      if (list is! List) return const [];
      return [for (final v in list) ?RunCommand.fromJson(v)];
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<RunCommand> cmds) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    const enc = JsonEncoder.withIndent('  ');
    await f.writeAsString(
      enc.convert({
        'commands': [for (final c in cmds) c.toJson()],
      }),
    );
  }
}
