#ifndef RUNNER_INSTANCE_HANDOFF_H_
#define RUNNER_INSTANCE_HANDOFF_H_

#include <string>
#include <vector>

// Native half of the single-instance guard (the Dart half is
// lib/util/single_instance.dart, which stays as the fallback).
//
// A second launch - Explorer double-click, "Open with", file association -
// only needs to hand its file paths to the running instance and exit, but
// doing that from Dart means booting the whole Flutter engine first
// (~2.6 s on a typical machine) just to run a 10 ms handshake. So the runner
// does it here, before FlutterViewController exists.
//
// Lock format and wire protocol mirror single_instance.dart exactly:
//   <exe dir>\settings\instance.lock = {"port":N,"token":"hex","pid":N}
//   send   {"token":"hex","args":["<absolute path>",...]}\n
//   reply  ok\n
// A lock whose pid is gone (crash / kill) is ignored; any other failure
// simply falls through to the normal startup, where Dart retries the same
// handshake and claims if that fails too.
//
// [file_args] are the command-line arguments that are file paths (UTF-16,
// as given - relative paths are absolutized here). Returns true when the
// running instance accepted them: the caller should exit without starting
// the engine.
bool TryHandoffToRunningInstance(const std::vector<std::wstring>& file_args);

#endif  // RUNNER_INSTANCE_HANDOFF_H_
