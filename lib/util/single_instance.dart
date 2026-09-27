// Single-instance guard: the first process binds a loopback socket and writes
// its port + a random token into `<settings>/instance.lock`; a later launch
// connects, forwards its command-line file paths, and exits. Stale locks
// (crash, other app on the port, corrupt file) just fail the handshake and the
// newcomer claims instead.
//
// Deliberately free of Flutter imports (log is a hook) so it stays
// headless-testable — see tool/single_instance_test.dart.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Where this module reports what happened; main() points it at [Log].
void Function(String message, {bool warn}) singleInstanceLog =
    (String message, {bool warn = false}) {};

const String _lockFileName = 'instance.lock';

class SingleInstance {
  SingleInstance._(this._server, this._lock);

  final ServerSocket _server;
  final File _lock;

  /// Set by [claim] on success; null in processes that never claimed
  /// (widget tests, or a second instance that handed off and exits).
  static SingleInstance? current;

  void Function(List<String> args)? _onArgs;
  final List<List<String>> _pending = [];

  /// Handler for args forwarded by later instances. Anything that arrived
  /// before a handler was attached is delivered immediately on attach.
  set onArgs(void Function(List<String> args)? f) {
    _onArgs = f;
    if (f == null) return;
    for (final a in _pending) {
      f(a);
    }
    _pending.clear();
  }

  /// Try to become THE instance for [dir].
  ///
  /// Another live instance found → forward [args] (absolutized — the paths
  /// are relative to THIS process's cwd) and return null; the caller should
  /// exit. Otherwise bind a fresh socket, (over)write the lock, and return
  /// the claimed guard.
  static Future<SingleInstance?> claim(String dir, List<String> args) async {
    final lock = File('$dir${Platform.pathSeparator}$_lockFileName');

    if (await _forward(lock, args)) {
      singleInstanceLog('single-instance: handed off to the running instance');
      return null;
    }

    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final token = _randomToken();
    try {
      await lock.parent.create(recursive: true);
      await lock.writeAsString(
        jsonEncode({'port': server.port, 'token': token, 'pid': pid}),
        encoding: utf8,
      );
    } catch (e) {
      // Unwritable settings dir: run without the guard rather than not at all.
      singleInstanceLog('single-instance: lock write failed ($e)', warn: true);
    }
    final si = SingleInstance._(server, lock);
    server.listen((sock) => si._handle(sock, token));
    singleInstanceLog('single-instance: claimed (port ${server.port})');
    current = si;
    return si;
  }

  /// True when a live instance accepted the handoff.
  static Future<bool> _forward(File lock, List<String> args) async {
    Socket? sock;
    try {
      final j = jsonDecode(await lock.readAsString(encoding: utf8));
      final port = (j as Map)['port'] as int;
      final token = j['token'] as String;
      // Windows refuses SetForegroundWindow from a background process (the
      // primary), so THIS freshly launched process — which holds foreground
      // rights — grants them to the primary before handing off; without this
      // the primary's window only flashes on the taskbar instead of raising.
      final primaryPid = j['pid'];
      // A lock left by a crashed/killed instance: on Windows a connect to the
      // dead loopback port is retried internally and only fails at our 800 ms
      // timeout, so every launch after an unclean exit paid that. Checking
      // whether the pid still exists is instant.
      if (primaryPid is int && !_processAlive(primaryPid)) {
        singleInstanceLog(
          'single-instance: stale lock (pid $primaryPid gone), claiming',
        );
        return false;
      }
      if (primaryPid is int) _grantForeground(primaryPid);
      sock = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 800),
      );
      sock.write(
        '${jsonEncode({
          'token': token,
          'args': [for (final a in args) File(a).absolute.path],
        })}\n',
      );
      await sock.flush();
      final reply = await utf8.decoder
          .bind(sock)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 2));
      return reply == 'ok';
    } catch (_) {
      return false; // no/stale/corrupt lock, dead port, foreign server, …
    } finally {
      sock?.destroy();
    }
  }

  /// The first line of [sock], capped: a LineSplitter over the raw stream
  /// would buffer whatever any local process cared to send (gigabytes within
  /// the 2-second window) before the token was even checked.
  static Future<String> _readLine(Socket sock, {int max = 64 * 1024}) async {
    final buf = BytesBuilder(copy: false);
    await for (final chunk in sock) {
      final nl = chunk.indexOf(10);
      buf.add(nl >= 0 ? chunk.sublist(0, nl) : chunk);
      if (buf.length > max) throw const FormatException('handoff line too long');
      if (nl >= 0) break;
    }
    return utf8.decode(buf.takeBytes());
  }

  /// One connection from a later instance: token-checked line of JSON in,
  /// 'ok' out, args to the handler (or buffered until one is attached).
  Future<void> _handle(Socket sock, String token) async {
    try {
      final line = await _readLine(sock).timeout(const Duration(seconds: 2));
      final j = jsonDecode(line) as Map;
      if (j['token'] != token) {
        singleInstanceLog('single-instance: rejected connect (bad token)',
            warn: true);
        return; // no 'ok' → the other side claims for itself
      }
      final args = [
        if (j['args'] is List)
          for (final a in j['args'] as List)
            if (a is String) a,
      ];
      sock.write('ok\n');
      await sock.flush();
      singleInstanceLog(
          'single-instance: received ${args.length} path(s) from a second launch');
      final f = _onArgs;
      if (f != null) {
        f(args);
      } else {
        _pending.add(args);
      }
    } catch (e) {
      singleInstanceLog('single-instance: bad handoff connect ($e)', warn: true);
    } finally {
      sock.destroy();
    }
  }

  /// Stop listening and drop the lock (best-effort; a stale lock is harmless —
  /// the next launch's handshake just fails and it claims).
  Future<void> close() async {
    await _server.close();
    try {
      await _lock.delete();
    } catch (_) {}
    if (identical(current, this)) current = null;
  }

  // user32!AllowSetForegroundWindow(pid) — best-effort, Windows only.
  static void _grantForeground(int targetPid) {
    if (!Platform.isWindows) return;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final allow = user32
          .lookupFunction<Int32 Function(Uint32), int Function(int)>(
            'AllowSetForegroundWindow',
          );
      allow(targetPid);
    } catch (_) {}
  }

  /// Whether a process with [pid] exists. Windows only (via OpenProcess;
  /// "access denied" still means it exists); elsewhere assumed alive — the
  /// connect attempt fails instantly there anyway.
  static bool _processAlive(int pid) {
    if (!Platform.isWindows) return true;
    try {
      final k32 = DynamicLibrary.open('kernel32.dll');
      final openProcess = k32
          .lookupFunction<
            IntPtr Function(Uint32, Int32, Uint32),
            int Function(int, int, int)
          >('OpenProcess');
      final closeHandle = k32
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'CloseHandle',
          );
      final getLastError = k32
          .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
      final getExitCode = k32
          .lookupFunction<
            Int32 Function(IntPtr, Pointer<Uint32>),
            int Function(int, Pointer<Uint32>)
          >('GetExitCodeProcess');
      const queryLimited = 0x1000; // PROCESS_QUERY_LIMITED_INFORMATION
      const accessDenied = 5;
      const stillActive = 259; // STILL_ACTIVE
      final h = openProcess(queryLimited, 0, pid);
      if (h == 0) return getLastError() == accessDenied;
      // A terminated process stays openable while anything (a parent shell,
      // a task manager) still holds a handle to it: its exit code tells.
      final code = calloc<Uint32>();
      try {
        final ok = getExitCode(h, code);
        return ok == 0 || code.value == stillActive;
      } finally {
        calloc.free(code);
        closeHandle(h);
      }
    } catch (_) {
      return true;
    }
  }

  static String _randomToken() {
    final r = Random.secure();
    return [for (var i = 0; i < 16; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }
}
