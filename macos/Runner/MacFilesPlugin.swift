import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

/// Sandbox-aware file access for the editor.
///
/// Under App Sandbox the app may only touch files the user pointed at. NSOpenPanel/NSSavePanel
/// hand back an implicit, process-lifetime grant for the chosen URL; a *security-scoped bookmark*
/// is what makes that grant survive a relaunch, which is what the session restore needs. Saving
/// cannot use the usual "sibling temp file + rename" trick either — the grant covers the file, not
/// its directory — so the atomic replace goes through FileManager.replaceItemAt, which is the one
/// API allowed to swap a granted destination.
///
/// Channel: `madedit2/mac_files`. Every method returns nil when the user cancels.
class MacFilesPlugin: NSObject {
  static let channelName = "madedit2/mac_files"

  /// The live plugin and its channel. Nothing else owns them: the method-call handler block is
  /// the only reference, so capturing `self` weakly there would let the plugin die the moment
  /// register() returns — the handler would then silently drop every call and the Dart future
  /// would never complete (no dialog, no error).
  private static var shared: MacFilesPlugin?
  private static var channel: FlutterMethodChannel?

  /// Kept so the panels can be presented as a sheet on the app window, which only exists later.
  private weak var registrar: FlutterPluginRegistrar?

  /// URLs currently held open by startAccessingSecurityScopedResource, keyed by path, with the
  /// number of outstanding claims — the same file can be opened by several panes.
  private var accessed: [String: (url: URL, count: Int)] = [:]

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger)
    let instance = MacFilesPlugin()
    instance.registrar = registrar
    shared = instance
    self.channel = channel
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

  /// Show [panel] without blocking: runModal() would spin a nested run loop on the platform
  /// thread the Flutter engine runs on. Attaches as a sheet when the app window is up.
  private func present(_ panel: NSSavePanel, _ done: @escaping (Bool) -> Void) {
    let handler: (NSApplication.ModalResponse) -> Void = { done($0 == .OK) }
    if let window = registrar?.view?.window ?? NSApplication.shared.mainWindow {
      panel.beginSheetModal(for: window, completionHandler: handler)
    } else {
      panel.begin(completionHandler: handler)
    }
  }

  /// Paths from application(_:openFiles:) that Dart has not collected yet
  /// (files opened at launch arrive before the Dart side listens).
  private static var pendingOpenFiles: [String] = []

  /// AppDelegate → here: push to Dart when it is listening, else buffer.
  static func deliverOpenFiles(_ paths: [String]) {
    guard let channel = channel else {
      pendingOpenFiles.append(contentsOf: paths)
      return
    }
    channel.invokeMethod("openFiles", arguments: paths) { reply in
      // A Dart handler that is not installed yet answers "not implemented":
      // keep the paths for the pendingOpenFiles poll.
      if reply is FlutterError || (reply as? NSObject) == FlutterMethodNotImplemented {
        pendingOpenFiles.append(contentsOf: paths)
      }
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "pendingOpenFiles":
      let p = MacFilesPlugin.pendingOpenFiles
      MacFilesPlugin.pendingOpenFiles = []
      result(p)
    case "openPanel":
      openPanel(multiple: args["allowsMultiple"] as? Bool ?? false, result: result)
    case "savePanel":
      savePanel(
        suggestedName: args["suggestedName"] as? String,
        directory: args["directory"] as? String,
        result: result)
    case "bookmark":
      guard let path = args["path"] as? String else { return result(nil) }
      result(bookmarkString(for: URL(fileURLWithPath: path)))
    case "startAccess":
      startAccess(bookmark: args["bookmark"] as? String, result: result)
    case "stopAccess":
      stopAccess(path: args["path"] as? String)
      result(nil)
    case "replaceItem":
      replaceItem(
        src: args["src"] as? String, dst: args["dst"] as? String, result: result)
    case "assocQuery":
      assocQuery(exts: args["exts"] as? [String] ?? [], result: result)
    case "assocSet":
      assocSet(exts: args["exts"] as? [String] ?? [], result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - File associations

  /// Default handler bundle id per extension: `{"txt": "com.apple.TextEdit"}`,
  /// with the UTI under `"txt.uti"` so the dialog can explain a dynamic type.
  /// An extension no app handles is simply absent.
  ///
  /// Uses NSWorkspace, not the older LaunchServices
  /// LSSetDefaultRoleHandlerForContentType/LSCopyDefaultRoleHandlerForContentType:
  /// on current macOS those return noErr while doing nothing, and read back a
  /// stale value right after a write, so the dialog could neither apply nor
  /// verify a change.
  private func assocQuery(exts: [String], result: @escaping FlutterResult) {
    var out: [String: String] = [:]
    for ext in exts {
      guard let type = UTType(filenameExtension: ext) else { continue }
      out["\(ext).uti"] = type.identifier
      if let url = NSWorkspace.shared.urlForApplication(toOpen: type),
        let id = Bundle(url: url)?.bundleIdentifier
      {
        out[ext] = id
      }
    }
    result(out)
  }

  /// Make this app the default handler for each extension. Returns a map of the
  /// ones that failed: `{"txt": "<message>"}` (empty map = all good).
  ///
  /// setDefaultApplication is asynchronous and reports real errors — including
  /// the sandbox refusing, which is why failures are surfaced per extension
  /// rather than assumed to have worked.
  private func assocSet(exts: [String], result: @escaping FlutterResult) {
    let me = Bundle.main.bundleURL
    var failed: [String: String] = [:]
    let group = DispatchGroup()
    let lock = NSLock()
    for ext in exts {
      guard let type = UTType(filenameExtension: ext) else {
        failed[ext] = "no UTI for .\(ext)"
        continue
      }
      group.enter()
      NSWorkspace.shared.setDefaultApplication(at: me, toOpen: type) { error in
        if let error = error {
          lock.lock()
          failed[ext] = error.localizedDescription
          lock.unlock()
        }
        group.leave()
      }
    }
    group.notify(queue: .main) { result(failed) }
  }

  // MARK: - Panels

  private func openPanel(multiple: Bool, result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = multiple
    present(panel) { [weak self] ok in
      guard let self = self, ok else { return result(nil) }
      result(panel.urls.map { self.entry(for: $0) })
    }
  }

  private func savePanel(
    suggestedName: String?, directory: String?, result: @escaping FlutterResult
  ) {
    let panel = NSSavePanel()
    if let name = suggestedName, !name.isEmpty { panel.nameFieldStringValue = name }
    if let dir = directory, !dir.isEmpty {
      panel.directoryURL = URL(fileURLWithPath: dir, isDirectory: true)
    }
    present(panel) { [weak self] ok in
      guard let self = self, ok, let url = panel.url else { return result(nil) }
      result(self.entry(for: url))
    }
  }

  /// `{path, bookmark}` for a URL the app can currently reach. When no bookmark could be made
  /// (a non-sandboxed build, or a URL with no grant) the key is left out rather than set to nil:
  /// a nil inside a [String: Any?] does not survive the standard message codec cleanly. The Dart
  /// side treats a missing key as "no bookmark" and falls back to the bare path.
  private func entry(for url: URL) -> [String: Any] {
    var out: [String: Any] = ["path": url.path]
    if let b = bookmarkString(for: url) { out["bookmark"] = b }
    return out
  }

  private func bookmarkString(for url: URL) -> String? {
    // A file handed over by LaunchServices (file association / "Open With") carries its grant
    // implicitly, so no start/stop is needed to bookmark it; a panel URL is likewise already live.
    guard
      let data = try? url.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    else { return nil }
    return data.base64EncodedString()
  }

  // MARK: - Security-scoped access

  /// Resolve a stored bookmark and start accessing it. Returns `{path, stale}` — when `stale` is
  /// true the caller should re-bookmark the path and store the fresh value.
  private func startAccess(bookmark: String?, result: @escaping FlutterResult) {
    guard let b = bookmark, let data = Data(base64Encoded: b) else { return result(nil) }
    var stale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: data, options: .withSecurityScope,
        relativeTo: nil, bookmarkDataIsStale: &stale)
    else { return result(nil) }
    guard url.startAccessingSecurityScopedResource() else { return result(nil) }
    let path = url.path
    if var held = accessed[path] {
      // Already held: balance the extra claim, and drop this one right away.
      held.count += 1
      accessed[path] = held
      url.stopAccessingSecurityScopedResource()
    } else {
      accessed[path] = (url: url, count: 1)
    }
    result(["path": path, "stale": stale])
  }

  private func stopAccess(path: String?) {
    guard let path = path, var held = accessed[path] else { return }
    held.count -= 1
    if held.count <= 0 {
      held.url.stopAccessingSecurityScopedResource()
      accessed.removeValue(forKey: path)
    } else {
      accessed[path] = held
    }
  }

  // MARK: - Atomic save

  /// Atomically replace `dst` with `src`. Unlike rename(2) this is permitted when only `dst`
  /// itself is granted, and it carries the original's permissions/metadata over.
  private func replaceItem(src: String?, dst: String?, result: @escaping FlutterResult) {
    guard let src = src, let dst = dst else {
      return result(
        FlutterError(code: "ARGS", message: "src and dst are required", details: nil))
    }
    let srcURL = URL(fileURLWithPath: src)
    let dstURL = URL(fileURLWithPath: dst)
    do {
      var resulting: NSURL?
      // No .usingNewMetadataOnly: that option means "take the NEW item's
      // metadata", i.e. the temp file's default permissions -- a 0600 secret
      // became 0644 and a script lost +x on every save. Without it the
      // original's permissions and dates carry over, as the doc comment says.
      try FileManager.default.replaceItem(
        at: dstURL, withItemAt: srcURL, backupItemName: nil,
        options: [], resultingItemURL: &resulting)
      result((resulting as URL?)?.path ?? dst)
    } catch {
      result(
        FlutterError(
          code: "REPLACE_FAILED", message: error.localizedDescription, details: nil))
    }
  }
}
