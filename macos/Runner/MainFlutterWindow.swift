import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    // Sandbox-aware open/save panels, security-scoped bookmarks and atomic replace.
    MacFilesPlugin.register(
      with: flutterViewController.registrar(forPlugin: "MacFilesPlugin"))

    super.awakeFromNib()
  }
}
