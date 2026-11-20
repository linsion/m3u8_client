import AVFoundation
import AVKit
import CoreImage
import Flutter
import GameController
import MediaPlayer
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  private let channelName = "com.linsion.m3u8_client/tv_platform"
  private let qrChannelName = "com.linsion.m3u8_client/qr_scanner"
  private let mediaSessionChannelName = "com.linsion.m3u8_client/media_session"
  private var notificationsChannel: FlutterMethodChannel?
  private var mediaSessionChannel: FlutterMethodChannel?
  private var pendingQrResult: FlutterResult?
  private var remoteCommandsConfigured = false
  private var cachedNowPlayingArtwork: MPMediaItemArtwork?
  private var cachedNowPlayingTrackTitle: String = ""

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Configure AVAudioSession for AirPlay 2 & Apple TV playback and disable idle timer
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.allowAirPlay])
      try session.setActive(true)
    } catch {}
    application.isIdleTimerDisabled = true

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: channelName,
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "getPlatformTvInfo":
          let isTvIdiom = UIDevice.current.userInterfaceIdiom == .tv
          let hasRemoteOrGamepad = !GCController.controllers().isEmpty
          result([
            "isTv": isTvIdiom,
            "hasController": hasRemoteOrGamepad,
            "platform": isTvIdiom ? "apple_tv" : "ios",
            "supportsAirPlay": true
          ])
        case "showAirPlayPicker":
          self?.presentAirPlayRoutePicker(from: controller)
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      let notifChannel = FlutterMethodChannel(
        name: "com.linsion.m3u8_client/notifications",
        binaryMessenger: controller.binaryMessenger
      )
      self.notificationsChannel = notifChannel
      UNUserNotificationCenter.current().delegate = self
      notifChannel.setMethodCallHandler { [weak self] call, result in
        self?.handleNotificationMethodCall(call: call, result: result)
      }

      let qrChannel = FlutterMethodChannel(
        name: qrChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      qrChannel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "scanCamera":
          self?.startIosCameraQrScan(from: controller, result: result)
        case "scanGallery":
          self?.startIosGalleryQrScan(from: controller, result: result)
        case "generateQrPng":
          let args = call.arguments as? [String: Any]
          let content = (args?["content"] as? String) ?? ""
          let size = CGFloat((args?["size"] as? Int) ?? 360)
          if let pngData = Self.generateQrPngData(content: content, size: size) {
            result(FlutterStandardTypedData(bytes: pngData))
          } else {
            result(nil)
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      let mediaChannel = FlutterMethodChannel(
        name: mediaSessionChannelName,
        binaryMessenger: controller.binaryMessenger
      )
      self.mediaSessionChannel = mediaChannel
      mediaChannel.setMethodCallHandler { [weak self] call, result in
        self?.handleMediaSessionMethodCall(call: call, result: result)
      }
      configureLockScreenRemoteCommands()
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func presentAirPlayRoutePicker(from viewController: UIViewController) {
    DispatchQueue.main.async {
      let routePicker = AVRoutePickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
      routePicker.isHidden = true
      if #available(iOS 13.0, *) {
        routePicker.prioritizesVideoDevices = true
      }
      viewController.view.addSubview(routePicker)
      for subview in routePicker.subviews {
        if let button = subview as? UIButton {
          button.sendActions(for: .touchUpInside)
          break
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        routePicker.removeFromSuperview()
      }
    }
  }

  private static func generateQrPngData(content: String, size: CGFloat) -> Data? {
    guard !content.isEmpty,
          let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(content.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let ciImg = filter.outputImage else { return nil }
    let scale = max(1.0, size / max(1.0, ciImg.extent.width))
    let transformed = ciImg.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let ctx = CIContext()
    guard let cgImg = ctx.createCGImage(transformed, from: transformed.extent) else { return nil }
    return UIImage(cgImage: cgImg).pngData()
  }

  private func configureLockScreenRemoteCommands() {
    guard !remoteCommandsConfigured else { return }
    remoteCommandsConfigured = true
    DispatchQueue.main.async {
      UIApplication.shared.beginReceivingRemoteControlEvents()
    }
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
      let posMs = Int(posEvent.positionTime * 1000.0)
      self?.sendMediaCommandToFlutter(action: "seek", positionMs: posMs)
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
      do {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.allowAirPlay])
        try session.setActive(true)
      } catch {}

      let title = (args["title"] as? String) ?? "流光云端音乐"
      let artist = (args["artist"] as? String) ?? "流光播放器"
      let album = (args["album"] as? String) ?? ""
      let isPlaying = (args["isPlaying"] as? Bool) ?? false
      let positionMs = (args["positionMs"] as? NSNumber)?.doubleValue ?? 0.0
      let durationMs = (args["durationMs"] as? NSNumber)?.doubleValue ?? 0.0
      let speed = (args["speed"] as? NSNumber)?.doubleValue ?? 1.0
      let queueIndex = (args["queueIndex"] as? NSNumber)?.intValue ?? 0
      let queueCount = (args["queueCount"] as? NSNumber)?.intValue ?? 1

      if title != cachedNowPlayingTrackTitle {
        cachedNowPlayingTrackTitle = title
        cachedNowPlayingArtwork = nil
      }

      if let typedBytes = args["coverBytes"] as? FlutterStandardTypedData,
         let img = UIImage(data: typedBytes.data) {
        cachedNowPlayingArtwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
      } else if cachedNowPlayingArtwork == nil {
        let placeholder = Self.generateVinylCoverArtwork(title: title, artist: artist, album: album)
        cachedNowPlayingArtwork = MPMediaItemArtwork(boundsSize: placeholder.size) { _ in placeholder }
      }

      var nowPlayingInfo: [String: Any] = [
        MPMediaItemPropertyTitle: title,
        MPMediaItemPropertyArtist: artist,
        MPMediaItemPropertyAlbumTitle: album,
        MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0.0, positionMs / 1000.0),
        MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0.0,
        MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        MPNowPlayingInfoPropertyPlaybackQueueIndex: max(0, queueIndex),
        MPNowPlayingInfoPropertyPlaybackQueueCount: max(1, queueCount),
      ]
      if durationMs > 0 {
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = durationMs / 1000.0
      }
      if let artwork = cachedNowPlayingArtwork {
        nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
      }
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
      result(true)

    case "clearMediaSession":
      cachedNowPlayingTrackTitle = ""
      cachedNowPlayingArtwork = nil
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      result(true)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func generateVinylCoverArtwork(title: String, artist: String, album: String) -> UIImage {
    let size = CGSize(width: 600, height: 600)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { ctx in
      let cg = ctx.cgContext
      let hash = abs((title + artist).hashValue)
      let palettes: [(UIColor, UIColor)] = [
        (UIColor(red: 0.08, green: 0.35, blue: 0.68, alpha: 1), UIColor(red: 0.04, green: 0.12, blue: 0.28, alpha: 1)),
        (UIColor(red: 0.42, green: 0.16, blue: 0.66, alpha: 1), UIColor(red: 0.14, green: 0.06, blue: 0.26, alpha: 1)),
        (UIColor(red: 0.07, green: 0.52, blue: 0.48, alpha: 1), UIColor(red: 0.04, green: 0.18, blue: 0.20, alpha: 1)),
        (UIColor(red: 0.68, green: 0.22, blue: 0.32, alpha: 1), UIColor(red: 0.22, green: 0.07, blue: 0.14, alpha: 1)),
        (UIColor(red: 0.72, green: 0.42, blue: 0.10, alpha: 1), UIColor(red: 0.22, green: 0.13, blue: 0.05, alpha: 1)),
      ]
      let pair = palettes[hash % palettes.count]
      if let grad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [pair.0.cgColor, pair.1.cgColor] as CFArray,
        locations: [0.0, 1.0]
      ) {
        cg.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 600, y: 600), options: [])
      }

      // Vinyl disc
      let center = CGPoint(x: 300, y: 245)
      let outerRect = CGRect(x: center.x - 165, y: center.y - 165, width: 330, height: 330)
      cg.setFillColor(UIColor(white: 0.08, alpha: 0.92).cgColor)
      cg.fillEllipse(in: outerRect)
      cg.setStrokeColor(UIColor(white: 1.0, alpha: 0.16).cgColor)
      cg.setLineWidth(3)
      cg.strokeEllipse(in: outerRect)

      for r: CGFloat in [135, 110, 85] {
        let groove = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        cg.setStrokeColor(UIColor(white: 1.0, alpha: 0.07).cgColor)
        cg.setLineWidth(1.5)
        cg.strokeEllipse(in: groove)
      }

      let labelRect = CGRect(x: center.x - 58, y: center.y - 58, width: 116, height: 116)
      cg.setFillColor(pair.0.cgColor)
      cg.fillEllipse(in: labelRect)

      let holeRect = CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)
      cg.setFillColor(UIColor(white: 0.06, alpha: 1.0).cgColor)
      cg.fillEllipse(in: holeRect)

      // Song title & artist text at bottom of cover
      let pStyle = NSMutableParagraphStyle()
      pStyle.alignment = .center
      pStyle.lineBreakMode = .byTruncatingTail

      let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 34, weight: .heavy),
        .foregroundColor: UIColor.white,
        .paragraphStyle: pStyle
      ]
      (title as NSString).draw(in: CGRect(x: 36, y: 445, width: 528, height: 48), withAttributes: titleAttrs)

      let subText = artist.isEmpty ? album : "\(artist) · \(album)"
      let subAttrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 22, weight: .semibold),
        .foregroundColor: UIColor(white: 0.85, alpha: 1.0),
        .paragraphStyle: pStyle
      ]
      (subText as NSString).draw(in: CGRect(x: 40, y: 502, width: 520, height: 34), withAttributes: subAttrs)
    }
  }

  private func handleNotificationMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    switch call.method {
    case "requestPermission":
      #if os(tvOS)
      let opts: UNAuthorizationOptions = [.badge]
      #else
      let opts: UNAuthorizationOptions = [.alert, .badge, .sound]
      #endif
      center.requestAuthorization(options: opts) { granted, _ in
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
      #if !os(tvOS)
      content.title = title
      if !subtitle.isEmpty {
        content.subtitle = subtitle
      }
      content.body = body
      if playSound {
        content.sound = .default
      }
      content.threadIdentifier = "telegram:\(accountId):\(peer)"
      #endif
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
        #if !os(tvOS)
        center.removeDeliveredNotifications(withIdentifiers: [id])
        #endif
        center.removePendingNotificationRequests(withIdentifiers: [id])
      }
      result(true)
    case "dismissAllNotifications":
      #if !os(tvOS)
      center.removeAllDeliveredNotifications()
      #endif
      center.removeAllPendingNotificationRequests()
      DispatchQueue.main.async {
        UIApplication.shared.applicationIconBadgeNumber = 0
        result(true)
      }
    case "setBadgeCount":
      let count = (call.arguments as? [String: Any])?["count"] as? Int ?? 0
      DispatchQueue.main.async {
        UIApplication.shared.applicationIconBadgeNumber = max(0, count)
        result(true)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    #if os(tvOS)
    completionHandler([.badge])
    #else
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .list, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
    #endif
  }

  override func userNotificationCenter(
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
      self?.notificationsChannel?.invokeMethod("onNotificationTapped", arguments: payload)
    }
    completionHandler()
  }

  private func finishQrScan(_ text: String?) {
    let cb = pendingQrResult
    pendingQrResult = nil
    cb?(text)
  }

  private func startIosCameraQrScan(from presenter: UIViewController, result: @escaping FlutterResult) {
    #if os(tvOS)
    result(nil)
    #else
    pendingQrResult = result
    let vc = IosQrCameraScannerViewController(
      onCodeScanned: { [weak self] code in
        self?.finishQrScan(code)
      },
      onPickGallery: { [weak self] in
        guard let self = self else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = self
        presenter.present(picker, animated: true)
      }
    )
    vc.modalPresentationStyle = .fullScreen
    presenter.present(vc, animated: true)
    #endif
  }

  private func startIosGalleryQrScan(from presenter: UIViewController, result: @escaping FlutterResult) {
    #if os(tvOS)
    result(nil)
    #else
    pendingQrResult = result
    let picker = UIImagePickerController()
    picker.sourceType = .photoLibrary
    picker.delegate = self
    presenter.present(picker, animated: true)
    #endif
  }

  #if !os(tvOS)
  func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
    picker.dismiss(animated: true)
    guard let image = info[.originalImage] as? UIImage,
          let ciImage = CIImage(image: image) else {
      finishQrScan("")
      return
    }
    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    let features = detector?.features(in: ciImage) ?? []
    for feature in features {
      if let qr = feature as? CIQRCodeFeature, let msg = qr.messageString, !msg.isEmpty {
        finishQrScan(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        return
      }
    }
    finishQrScan("")
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
    finishQrScan(nil)
  }
  #endif
}

#if !os(tvOS)
class IosQrCameraScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  private let session = AVCaptureSession()
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private let onCodeScanned: (String?) -> Void
  private let onPickGallery: () -> Void
  private var didFinish = false

  init(onCodeScanned: @escaping (String?) -> Void, onPickGallery: @escaping () -> Void) {
    self.onCodeScanned = onCodeScanned
    self.onPickGallery = onPickGallery
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    guard let videoDevice = AVCaptureDevice.default(for: .video),
          let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
          session.canAddInput(videoInput) else {
      setupOverlayUI()
      return
    }
    session.addInput(videoInput)

    let metadataOutput = AVCaptureMetadataOutput()
    if session.canAddOutput(metadataOutput) {
      session.addOutput(metadataOutput)
      metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
      if metadataOutput.availableMetadataObjectTypes.contains(.qr) {
        metadataOutput.metadataObjectTypes = [.qr]
      }
    }

    let preview = AVCaptureVideoPreviewLayer(session: session)
    preview.frame = view.layer.bounds
    preview.videoGravity = .resizeAspectFill
    view.layer.addSublayer(preview)
    previewLayer = preview

    setupOverlayUI()
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.session.startRunning()
    }
  }

  private func setupOverlayUI() {
    let titleLabel = UILabel()
    titleLabel.text = "扫描代理订阅 / 节点二维码"
    titleLabel.textColor = .white
    titleLabel.font = UIFont.boldSystemFont(ofSize: 17)
    titleLabel.textAlignment = .center
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(titleLabel)

    let boxView = UIView()
    boxView.layer.borderColor = UIColor.systemTeal.cgColor
    boxView.layer.borderWidth = 2.5
    boxView.layer.cornerRadius = 16
    boxView.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.08)
    boxView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(boxView)

    let galleryBtn = UIButton(type: .system)
    galleryBtn.setTitle("从相册识别", for: .normal)
    galleryBtn.setTitleColor(.white, for: .normal)
    galleryBtn.backgroundColor = UIColor.systemBlue
    galleryBtn.layer.cornerRadius = 20
    galleryBtn.contentEdgeInsets = UIEdgeInsets(top: 10, left: 22, bottom: 10, right: 22)
    galleryBtn.addTarget(self, action: #selector(handleGalleryTap), for: .touchUpInside)
    galleryBtn.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(galleryBtn)

    let cancelBtn = UIButton(type: .system)
    cancelBtn.setTitle("取消关闭", for: .normal)
    cancelBtn.setTitleColor(.white, for: .normal)
    cancelBtn.backgroundColor = UIColor.darkGray
    cancelBtn.layer.cornerRadius = 20
    cancelBtn.contentEdgeInsets = UIEdgeInsets(top: 10, left: 22, bottom: 10, right: 22)
    cancelBtn.addTarget(self, action: #selector(handleCancelTap), for: .touchUpInside)
    cancelBtn.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(cancelBtn)

    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
      titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      boxView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      boxView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      boxView.widthAnchor.constraint(equalToConstant: 250),
      boxView.heightAnchor.constraint(equalToConstant: 250),
      galleryBtn.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
      galleryBtn.trailingAnchor.constraint(equalTo: view.centerXAnchor, constant: -10),
      cancelBtn.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
      cancelBtn.leadingAnchor.constraint(equalTo: view.centerXAnchor, constant: 10),
    ])
  }

  @objc private func handleGalleryTap() {
    guard !didFinish else { return }
    didFinish = true
    session.stopRunning()
    dismiss(animated: true) { [weak self] in
      self?.onPickGallery()
    }
  }

  @objc private func handleCancelTap() {
    guard !didFinish else { return }
    didFinish = true
    session.stopRunning()
    dismiss(animated: true) { [weak self] in
      self?.onCodeScanned(nil)
    }
  }

  func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
    guard !didFinish,
          let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
          let text = obj.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else { return }
    didFinish = true
    session.stopRunning()
    dismiss(animated: true) { [weak self] in
      self?.onCodeScanned(text)
    }
  }
}
#endif
