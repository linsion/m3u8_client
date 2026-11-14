import AVFoundation
import AVKit
import Flutter
import GameController
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let channelName = "com.linsion.m3u8_client/tv_platform"
  private var notificationsChannel: FlutterMethodChannel?

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
}
