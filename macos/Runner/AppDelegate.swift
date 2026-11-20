import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?
  private var sleepPreventActivity: NSObjectProtocol?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    sleepPreventActivity = ProcessInfo.processInfo.beginActivity(
      options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
      reason: "流光视频运行期间保持屏幕常亮并防止系统进入休眠"
    )
    setupStatusMenuItem()
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showMainWindow()
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  private func setupStatusMenuItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      if #available(macOS 11.0, *),
         let img = NSImage(systemSymbolName: "play.tv.fill", accessibilityDescription: "流光视频") {
        img.isTemplate = true
        button.image = img
      } else {
        button.title = "流光"
      }
      button.toolTip = "流光视频"
    }
    let menu = NSMenu()
    let showItem = NSMenuItem(
      title: "显示主窗口",
      action: #selector(handleShowMainWindow(_:)),
      keyEquivalent: ""
    )
    showItem.target = self
    menu.addItem(showItem)
    menu.addItem(NSMenuItem.separator())
    let quitItem = NSMenuItem(
      title: "退出流光视频",
      action: #selector(handleQuitApp(_:)),
      keyEquivalent: "q"
    )
    quitItem.target = self
    menu.addItem(quitItem)
    item.menu = menu
    self.statusItem = item
  }

  @objc private func handleShowMainWindow(_ sender: Any?) {
    showMainWindow()
  }

  @objc private func handleQuitApp(_ sender: Any?) {
    NSApp.terminate(sender)
  }

  func showMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    for window in NSApp.windows {
      if window is MainFlutterWindow {
        if window.isMiniaturized {
          window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        return
      }
    }
    if let firstWindow = NSApp.windows.first {
      if firstWindow.isMiniaturized {
        firstWindow.deminiaturize(nil)
      }
      firstWindow.makeKeyAndOrderFront(nil)
    }
  }
}
