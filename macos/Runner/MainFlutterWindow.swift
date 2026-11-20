import AVKit
import Cocoa
import CoreImage
import FlutterMacOS
import GameController
import MediaPlayer
import UserNotifications

/// Transparent AppKit drag-destination overlay view placed over FlutterView.
/// `hitTest` returns `nil` so normal mouse clicks/scrolls/hovers go straight to FlutterView,
/// while AppKit's internal `_hitTest:dragTypes:` routes drag-and-drop events here.
final class MacFileDropOverlayView: NSView {
  weak var hostWindow: MainFlutterWindow?

  override func hitTest(_ point: NSPoint) -> NSView? {
    return nil
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    return hostWindow?.draggingEntered(sender) ?? []
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    return hostWindow?.draggingUpdated(sender) ?? []
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    hostWindow?.draggingExited(sender)
  }

  override func draggingEnded(_ sender: NSDraggingInfo) {
    hostWindow?.draggingEnded(sender)
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return hostWindow?.prepareForDragOperation(sender) ?? false
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return hostWindow?.performDragOperation(sender) ?? false
  }
}

class MainFlutterWindow: NSWindow, NSWindowDelegate, NSDraggingDestination, UNUserNotificationCenterDelegate {
  private let channelName = "com.linsion.m3u8_client/tv_platform"
  private var notificationsChannel: FlutterMethodChannel?
  private var utilsChannel: FlutterMethodChannel?
  private var mediaSessionChannel: FlutterMethodChannel?
  private var dropOverlayView: MacFileDropOverlayView?
  private var remoteCommandsConfigured = false
  private var cachedNowPlayingArtwork: MPMediaItemArtwork?
  private var cachedNowPlayingTrackTitle: String = ""

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
    self.utilsChannel = utilsChannel
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

    let dragTypes: [NSPasteboard.PasteboardType] = [
      .fileURL,
      .URL,
      .png,
      .tiff,
      NSPasteboard.PasteboardType("public.file-url"),
      NSPasteboard.PasteboardType("public.url"),
      NSPasteboard.PasteboardType("public.jpeg"),
      NSPasteboard.PasteboardType("public.heic"),
      NSPasteboard.PasteboardType("NSFilenamesPboardType"),
    ]
    self.registerForDraggedTypes(dragTypes)
    let overlay = MacFileDropOverlayView(frame: flutterViewController.view.bounds)
    overlay.autoresizingMask = [.width, .height]
    overlay.hostWindow = self
    overlay.registerForDraggedTypes(dragTypes)
    flutterViewController.view.addSubview(overlay, positioned: .above, relativeTo: nil)
    self.dropOverlayView = overlay

    let notifChannel = FlutterMethodChannel(
      name: "com.linsion.m3u8_client/notifications",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    self.notificationsChannel = notifChannel
    UNUserNotificationCenter.current().delegate = self
    notifChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleNotificationMethodCall(call: call, result: result)
    }

    let mediaChannel = FlutterMethodChannel(
      name: "com.linsion.m3u8_client/media_session",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    self.mediaSessionChannel = mediaChannel
    mediaChannel.setMethodCallHandler { [weak self] call, result in
      self?.handleMediaSessionMethodCall(call: call, result: result)
    }
    configureMacRemoteCommands()

    let qrChannel = FlutterMethodChannel(
      name: "com.linsion.m3u8_client/qr_scanner",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    qrChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "generateQrPng":
        let args = call.arguments as? [String: Any]
        let content = (args?["content"] as? String) ?? ""
        let size = CGFloat((args?["size"] as? Int) ?? 360)
        if let pngData = Self.generateMacQrPngData(content: content, size: size) {
          result(FlutterStandardTypedData(bytes: pngData))
        } else {
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
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

  private static func generateMacQrPngData(content: String, size: CGFloat) -> Data? {
    guard !content.isEmpty,
          let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(content.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let ciImg = filter.outputImage else { return nil }
    let scale = max(1.0, size / max(1.0, ciImg.extent.width))
    let transformed = ciImg.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let rep = NSCIImageRep(ciImage: transformed)
    let nsImg = NSImage(size: rep.size)
    nsImg.addRepresentation(rep)
    guard let tiff = nsImg.tiffRepresentation,
          let bmp = NSBitmapImageRep(data: tiff) else { return nil }
    return bmp.representation(using: .png, properties: [:])
  }

  private func configureMacRemoteCommands() {
    guard !remoteCommandsConfigured else { return }
    remoteCommandsConfigured = true
    let commandCenter = MPRemoteCommandCenter.shared()
    commandCenter.playCommand.isEnabled = true
    commandCenter.playCommand.addTarget { [weak self] _ in
      self?.sendMediaCommandToFlutter(action: "play")
      return .success
    }
    commandCenter.pauseCommand.isEnabled = true
    commandCenter.pauseCommand.addTarget { [weak self] _ in
      self?.sendMediaCommandToFlutter(action: "pause")
      return .success
    }
    commandCenter.togglePlayPauseCommand.isEnabled = true
    commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.sendMediaCommandToFlutter(action: "togglePlayPause")
      return .success
    }
    commandCenter.nextTrackCommand.isEnabled = true
    commandCenter.nextTrackCommand.addTarget { [weak self] _ in
      self?.sendMediaCommandToFlutter(action: "next")
      return .success
    }
    commandCenter.previousTrackCommand.isEnabled = true
    commandCenter.previousTrackCommand.addTarget { [weak self] _ in
      self?.sendMediaCommandToFlutter(action: "previous")
      return .success
    }
    commandCenter.stopCommand.isEnabled = true
    commandCenter.stopCommand.addTarget { [weak self] _ in
      self?.sendMediaCommandToFlutter(action: "stop")
      return .success
    }
    commandCenter.changePlaybackPositionCommand.isEnabled = true
    commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      self?.sendMediaCommandToFlutter(action: "seek", positionMs: Int(posEvent.positionTime * 1000.0))
      return .success
    }
  }

  private func sendMediaCommandToFlutter(action: String, positionMs: Int? = nil) {
    DispatchQueue.main.async { [weak self] in
      var payload: [String: Any] = ["action": action]
      if let posMs = positionMs {
        payload["positionMs"] = posMs
      }
      self?.mediaSessionChannel?.invokeMethod("onMediaCommand", arguments: payload)
    }
  }

  private func handleMediaSessionMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "updateMediaSession":
      guard let args = call.arguments as? [String: Any] else {
        result(false)
        return
      }
      let title = (args["title"] as? String) ?? "流光云端音乐"
      let artist = (args["artist"] as? String) ?? "流光播放器"
      let album = (args["album"] as? String) ?? ""
      let isPlaying = (args["isPlaying"] as? Bool) ?? false
      let positionMs = (args["positionMs"] as? NSNumber)?.doubleValue ?? 0.0
      let durationMs = (args["durationMs"] as? NSNumber)?.doubleValue ?? 0.0
      let speed = (args["speed"] as? NSNumber)?.doubleValue ?? 1.0

      if title != cachedNowPlayingTrackTitle {
        cachedNowPlayingTrackTitle = title
        cachedNowPlayingArtwork = nil
      }
      if let typedBytes = args["coverBytes"] as? FlutterStandardTypedData,
         let img = NSImage(data: typedBytes.data) {
        cachedNowPlayingArtwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
      }

      var nowPlayingInfo: [String: Any] = [
        MPMediaItemPropertyTitle: title,
        MPMediaItemPropertyArtist: artist,
        MPMediaItemPropertyAlbumTitle: album,
        MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0.0, positionMs / 1000.0),
        MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0.0,
        MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
      ]
      if durationMs > 0 {
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = durationMs / 1000.0
      }
      if let artwork = cachedNowPlayingArtwork {
        nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
      }
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
      MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
      result(true)

    case "clearMediaSession":
      cachedNowPlayingTrackTitle = ""
      cachedNowPlayingArtwork = nil
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      MPNowPlayingInfoCenter.default().playbackState = .stopped
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func buildFilePayloadItem(for url: URL) -> [String: Any]? {
    let resolved = (url as NSURL).filePathURL ?? url
    guard resolved.isFileURL else { return nil }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), !isDir.boolValue else {
      return nil
    }
    let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path)
    let fileSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0
    guard fileSize > 0 else { return nil }
    if fileSize <= 8 * 1024 * 1024, let data = try? Data(contentsOf: resolved), !data.isEmpty {
      return [
        "name": resolved.lastPathComponent,
        "path": resolved.path,
        "size": fileSize,
        "bytes": FlutterStandardTypedData(bytes: data)
      ]
    }
    return [
      "name": resolved.lastPathComponent,
      "path": resolved.path,
      "size": fileSize,
      "bytes": FlutterStandardTypedData(bytes: Data())
    ]
  }

  private static func buildFilePayloadItems(for url: URL, limit: Int = 10) -> [[String: Any]] {
    let resolved = (url as NSURL).filePathURL ?? url
    guard resolved.isFileURL else { return [] }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) else {
      return []
    }
    if !isDir.boolValue {
      if let item = buildFilePayloadItem(for: resolved) {
        return [item]
      }
      return []
    }
    var results: [[String: Any]] = []
    if let children = try? FileManager.default.contentsOfDirectory(
      at: resolved,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) {
      for child in children {
        if results.count >= limit { break }
        if let item = buildFilePayloadItem(for: child) {
          results.append(item)
        }
      }
    }
    return results
  }

  private static func extractFileURLs(from pb: NSPasteboard) -> [URL] {
    var result: [URL] = []
    var seenPaths = Set<String>()

    func appendResolved(_ url: URL) {
      let resolved = (url as NSURL).filePathURL ?? url
      guard resolved.isFileURL else { return }
      let path = resolved.path
      guard !path.isEmpty, !seenPaths.contains(path) else { return }
      seenPaths.insert(path)
      result.append(resolved)
    }

    if let urls = pb.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL] {
      for u in urls {
        appendResolved(u)
      }
    }

    if result.isEmpty,
       let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
      for u in urls {
        appendResolved(u)
      }
    }

    if result.isEmpty,
       let filenames = pb.propertyList(
         forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
       ) as? [String] {
      for path in filenames where !path.isEmpty {
        appendResolved(URL(fileURLWithPath: path))
      }
    }

    if result.isEmpty, let items = pb.pasteboardItems {
      for item in items {
        if let str = item.string(forType: .fileURL)
            ?? item.string(forType: NSPasteboard.PasteboardType("public.file-url")),
           let u = URL(string: str) {
          appendResolved(u)
        } else if let data = item.data(forType: .fileURL)
            ?? item.data(forType: NSPasteboard.PasteboardType("public.file-url")),
                  let u = URL(dataRepresentation: data, relativeTo: nil) {
          appendResolved(u)
        }
      }
    }

    return result
  }

  private func hasValidDragContent(_ sender: NSDraggingInfo) -> Bool {
    let pb = sender.draggingPasteboard
    if !Self.extractFileURLs(from: pb).isEmpty {
      return true
    }
    if NSImage.canInit(with: pb) {
      return true
    }
    return false
  }

  @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard hasValidDragContent(sender) else { return [] }
    DispatchQueue.main.async { [weak self] in
      self?.utilsChannel?.invokeMethod("onFileDragUpdated", arguments: ["active": true])
    }
    return .copy
  }

  @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard hasValidDragContent(sender) else { return [] }
    return .copy
  }

  @objc func draggingExited(_ sender: NSDraggingInfo?) {
    DispatchQueue.main.async { [weak self] in
      self?.utilsChannel?.invokeMethod("onFileDragUpdated", arguments: ["active": false])
    }
  }

  @objc func draggingEnded(_ sender: NSDraggingInfo) {
    DispatchQueue.main.async { [weak self] in
      self?.utilsChannel?.invokeMethod("onFileDragUpdated", arguments: ["active": false])
    }
  }

  @objc func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return hasValidDragContent(sender)
  }

  @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let pb = sender.draggingPasteboard
    var items: [[String: Any]] = []
    let urls = Self.extractFileURLs(from: pb)
    for url in urls {
      if items.count >= 10 { break }
      let extracted = Self.buildFilePayloadItems(for: url, limit: 10 - items.count)
      items.append(contentsOf: extracted)
    }
    if items.isEmpty,
       let image = NSImage(pasteboard: pb),
       let tiff = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff),
       let pngData = bitmap.representation(using: .png, properties: [:]) {
      let ts = Int(Date().timeIntervalSince1970)
      items.append([
        "name": "拖拽图片-\(ts).png",
        "size": pngData.count,
        "bytes": FlutterStandardTypedData(bytes: pngData)
      ])
    }
    DispatchQueue.main.async { [weak self] in
      self?.utilsChannel?.invokeMethod("onFileDragUpdated", arguments: ["active": false])
      if !items.isEmpty {
        self?.utilsChannel?.invokeMethod("onFilesDropped", arguments: items)
      }
    }
    return !items.isEmpty
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
          if let item = Self.buildFilePayloadItem(for: url) {
            items.append(item)
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
          if let item = Self.buildFilePayloadItem(for: url) {
            result(item)
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
