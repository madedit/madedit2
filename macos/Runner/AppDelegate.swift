import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// Files handed over by LaunchServices (Finder double-click / "Open With" /
  /// file associations). These arrive with sandbox authorization; the paths
  /// go to Dart through MacFilesPlugin, buffered until it asks for them.
  ///
  /// This has to be the URL-based method: FlutterAppDelegate already implements
  /// `application:openURLs:`, and AppKit only calls the deprecated
  /// `application:openFiles:` when the delegate implements *no* newer variant —
  /// so an override of that one is dead code and every association silently
  /// opened nothing. super still runs, so plugins that route URLs keep working.
  override func application(_ application: NSApplication, open urls: [URL]) {
    let paths = urls.filter { $0.isFileURL }.map { $0.path }
    if !paths.isEmpty {
      MacFilesPlugin.deliverOpenFiles(paths)
    }
    super.application(application, open: urls)
  }
}
