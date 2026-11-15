import AVKit
import Cocoa
import FlutterMacOS
import GameController
import UserNotifications

class MainFlutterWindow: NSWindow, NSWindowDelegate, UNUserNotificationCenterDelegate {
  private let channelName = "com.linsion.m3u8_client/tv_platform"
  private var notificationsChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.title = "流光视频"
    self.isReleasedWhenClosed = false
    self.delegate = self
    self.minSize = NSSize(width: 960, height: 640)
    if let screen = NSScreen.main {
      let screenRect = screen.visibleFrame
      let width = min(1400.0, screenRect.width * 0.88)
      let height = min(880.0, screenRect.height * 0.88)
      let x = screenRect.origin.x + (screenRect.width - width) / 2.0
      let y = screenRect.origin.y + (screenRect.height - height) / 2.0
      self.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "getPlatformTvInfo":
        let hasController = !GCController.controllers().isEmpty
        result([
          "isTv": false,
          "hasController": hasController,
          "platform": "macos",
          "supportsAirPlay": true
        ])
      case "showAirPlayPicker":
        self?.presentMacAirPlayRoutePicker(in: flutterViewController.view)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let utilsChannel = FlutterMethodChannel(
      name: "com.linsion.m3u8_client/native_utils",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    utilsChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "pickFiles":
        let args = call.arguments as? [String: Any]
        let mediaOnly = (args?["mediaOnly"] as? Bool) ?? false
        self?.presentMacFilePicker(mediaOnly: mediaOnly, result: result)
      case "readClipboardImage":
        self?.readMacClipboardImage(result: result)
      case "captureInteractiveScreenshot":
        self?.captureMacInteractiveScreenshot(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let notifChannel = FlutterMethodChannel(
      name: "com.linsion.m3u8_client/notifications",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    self.notificationsChannel = notifChannel
    UNUserNotificationCenter.current().delegate = self
    notifChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleNotificationMethodCall(call: call, result: result)
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if self.styleMask.contains(.fullScreen) {
      self.toggleFullScreen(nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
        self?.orderOut(nil)
      }
    } else {
      self.orderOut(nil)
    }
    return false
  }

  private func presentMacAirPlayRoutePicker(in hostView: NSView) {
    DispatchQueue.main.async {
      let picker = AVRoutePickerView(frame: NSRect(x: 20, y: 20, width: 32, height: 32))
      picker.isRoutePickerButtonBordered = false
      hostView.addSubview(picker)
      for subview in picker.subviews {
        if let btn = subview as? NSButton {
          btn.performClick(nil)
          break
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        picker.removeFromSuperview()
      }
    }
  }

  private func presentMacFilePicker(mediaOnly: Bool, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      let panel = NSOpenPanel()
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = true
      panel.title = mediaOnly ? "选择图片或视频发送" : "选择要发送的文件"
      if mediaOnly {
        panel.allowedFileTypes = [
          "png", "jpg", "jpeg", "gif", "webp", "bmp", "heic",
          "mp4", "mov", "mkv", "webm", "avi", "m4v"
        ]
      }
      panel.beginSheetModal(for: self) { response in
        guard response == .OK else {
          result([])
          return
        }
        var items: [[String: Any]] = []
        for url in panel.urls.prefix(10) {
          if let data = try? Data(contentsOf: url), !data.isEmpty {
            items.append([
              "name": url.lastPathComponent,
              "path": url.path,
              "bytes": FlutterStandardTypedData(bytes: data)
            ])
          }
        }
        result(items)
      }
    }
  }

  private func readMacClipboardImage(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      let pb = NSPasteboard.general
      if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [ URL ] {
        for url in urls where url.isFileURL {
          if let data = try? Data(contentsOf: url), !data.isEmpty {
            result([
              "name": url.lastPathComponent,
              "path": url.path,
              "bytes": FlutterStandardTypedData(bytes: data)
            ])
            return
          }
        }
      }
      if let image = NSImage(pasteboard: pb),
         let tiff = image.tiffRepresentation,
         let bitmap = NSBitmapImageRep(data: tiff),
         let pngData = bitmap.representation(using: .png, properties: [:]) {
        let ts = Int(Date().timeIntervalSince1970)
        result([
          "name": "粘贴图片-\(ts).png",
          "bytes": FlutterStandardTypedData(bytes: pngData)
        ])
        return
      }
      result(nil)
    }
  }

  private func captureMacInteractiveScreenshot(result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      proc.arguments = ["-i", "-c"]
      do {
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus == 0 {
          DispatchQueue.main.async {
            self.readMacClipboardImage(result: result)
          }
        } else {
          DispatchQueue.main.async {
            result(nil)
          }
        }
      } catch {
        DispatchQueue.main.async {
          result(nil)
        }
      }
    }
  }

  private func handleNotificationMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    switch call.method {
    case "requestPermission":
      center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
        DispatchQueue.main.async {
          result(granted)
        }
      }
    case "getPermissionStatus":
      center.getNotificationSettings { settings in
        let granted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        DispatchQueue.main.async {
          result(granted)
        }
      }
    case "showNotification":
      guard let args = call.arguments as? [String: Any] else {
        result(false)
        return
      }
      let key = (args["key"] as? String) ?? UUID().uuidString
      let title = (args["title"] as? String) ?? "Telegram 新消息"
      let subtitle = (args["subtitle"] as? String) ?? ""
      let body = (args["body"] as? String) ?? ""
      let accountId = (args["accountId"] as? String) ?? "default"
      let peer = (args["peer"] as? String) ?? ""
      let messageId = (args["messageId"] as? Int) ?? 0
      let playSound = (args["playSound"] as? Bool) ?? true

      let content = UNMutableNotificationContent()
      content.title = title
      if !subtitle.isEmpty {
        content.subtitle = subtitle
      }
      content.body = body
      if playSound {
        content.sound = .default
      }
      content.threadIdentifier = "telegram:\(accountId):\(peer)"
      content.userInfo = [
        "key": key,
        "accountId": accountId,
        "peer": peer,
        "messageId": messageId
      ]

      let identifier = "tg:\(key)"
      let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
      center.add(request) { error in
        DispatchQueue.main.async {
          result(error == nil)
        }
      }
    case "dismissNotification":
      if let args = call.arguments as? [String: Any],
         let key = args["key"] as? String {
        let id = "tg:\(key)"
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
      }
      result(true)
    case "dismissAllNotifications":
      center.removeAllDeliveredNotifications()
      center.removeAllPendingNotificationRequests()
      DispatchQueue.main.async {
        NSApp.dockTile.badgeLabel = nil
      }
      result(true)
    case "setBadgeCount":
      let count = (call.arguments as? [String: Any])?["count"] as? Int ?? 0
      DispatchQueue.main.async {
        NSApp.dockTile.badgeLabel = count > 0 ? (count > 99 ? "99+" : "\(count)") : nil
        result(true)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(macOS 11.0, *) {
      completionHandler([.banner, .list, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    let payload: [String: Any] = [
      "key": (info["key"] as? String) ?? "",
      "accountId": (info["accountId"] as? String) ?? "default",
      "peer": (info["peer"] as? String) ?? "",
      "messageId": (info["messageId"] as? Int) ?? 0
    ]
    DispatchQueue.main.async { [weak self] in
      NSApp.activate(ignoringOtherApps: true)
      self?.makeKeyAndOrderFront(nil)
      self?.notificationsChannel?.invokeMethod("onNotificationTapped", arguments: payload)
    }
    completionHandler()
  }
}
