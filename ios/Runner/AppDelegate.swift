import AVFoundation
import AVKit
import CoreImage
import Flutter
import GameController
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  private let channelName = "com.linsion.m3u8_client/tv_platform"
  private let qrChannelName = "com.linsion.m3u8_client/qr_scanner"
  private var notificationsChannel: FlutterMethodChannel?
  private var pendingQrResult: FlutterResult?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Configure AVAudioSession for AirPlay 2 & Apple TV playback
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
      try session.setActive(true)
    } catch {}

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
        default:
          result(FlutterMethodNotImplemented)
        }
      }
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
