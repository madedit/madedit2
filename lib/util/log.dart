import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

/// Log level.
enum LogLevel { debug, info, warn, error }

/// Global logger: writes to the console (`debugPrint`) by default; when [init] is
/// given a `fileDir`, it also writes a copy to `<fileDir>/<start-time>.log`.
///
/// Usage:
///   - `await Log.instance.init(fileDir: ...)` (at app startup; file is optional).
///   - `Log.instance.i('...')` / `.d` / `.w` / `.e`.
///   - The file side depends on no other module (the directory path is passed in
///     by the caller), to avoid a circular dependency with config_loader.
class Log {
  Log._();
  static final Log instance = Log._();

  bool _toConsole = true;
  IOSink? _file;
  String? _filePath;

  /// Current log file path (null if no file is open).
  String? get filePath => _filePath;

  /// Initialize. [toConsole] controls whether to print to the console; when
  /// [fileDir] is non-null, logs are also written to `<fileDir>/<start-time>.log`
  /// (if opening the file fails, it just falls back to console and does not throw).
  Future<void> init({bool toConsole = true, String? fileDir}) async {
    _toConsole = toConsole;
    if (fileDir == null) return;
    try {
      final dir = Directory(fileDir);
      await dir.create(recursive: true);
      final path = '${dir.path}${Platform.pathSeparator}${_stamp(DateTime.now())}.log';
      _file = File(path).openWrite();
      _filePath = path;
      // Everything logged before the file existed (single-instance handshake,
      // settings load, startup marks) would otherwise only reach the console —
      // which a release GUI build does not have.
      for (final line in _early) {
        _file!.writeln(line);
      }
      _early.clear();
      i('also logging to file: $path');
    } catch (e) {
      _file = null;
      _filePath = null;
      if (_toConsole) debugPrint('[log] failed to open log file (console only): $e');
    }
  }

  Timer? _flushTimer;

  // Lines logged before init() opened the file (bounded; replayed into it).
  final List<String> _early = [];
  static const int _earlyMax = 200;

  // Startup timing: runs from the first touch of the logger (top of main()).
  final Stopwatch _startup = Stopwatch()..start();
  int _lastMark = 0;

  /// Log a startup phase with the time since the previous [mark] and since
  /// the process's Dart side started. Grep the log for `startup:` to see
  /// where launch time goes.
  void mark(String phase) {
    final t = _startup.elapsedMilliseconds;
    // The epoch stamp lets the time before main() (engine + runner) be read
    // off against the process start time.
    i(
      'startup: $phase  +${t - _lastMark} ms  (t=$t ms, '
      'epoch ${DateTime.now().millisecondsSinceEpoch})',
    );
    _lastMark = t;
  }

  void log(LogLevel level, String msg) {
    final line =
        '${DateTime.now().toIso8601String()} [${level.name.toUpperCase()}] $msg';
    if (_toConsole) debugPrint(line);
    final f = _file;
    if (f == null) {
      if (_early.length < _earlyMax) _early.add(line);
      return;
    }
    f.writeln(line);
    // IOSink buffers, and a GUI app that is closed (or killed) never runs anything after this —
    // without an auto-flush the log file would only ever contain whatever was flushed at startup.
    _flushTimer ??= Timer(const Duration(milliseconds: 300), () {
      _flushTimer = null;
      f.flush();
    });
  }

  void d(String msg) => log(LogLevel.debug, msg);
  void i(String msg) => log(LogLevel.info, msg);
  void w(String msg) => log(LogLevel.warn, msg);
  void e(String msg) => log(LogLevel.error, msg);

  /// Flush the file buffer to disk (used to ensure startup logs are written out).
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _file?.flush();
  }

  Future<void> close() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _file?.flush();
    await _file?.close();
    _file = null;
    _filePath = null;
  }

  // Timestamp used in the file name: yyyyMMdd-HHmmss.
  String _stamp(DateTime t) =>
      '${t.year}${_pad(t.month)}${_pad(t.day)}-${_pad(t.hour)}${_pad(t.minute)}${_pad(t.second)}';
  String _pad(int n) => n.toString().padLeft(2, '0');
}
