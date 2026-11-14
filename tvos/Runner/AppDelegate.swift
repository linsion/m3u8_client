import AVFoundation
import GameController
import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
      try session.setActive(true)
    } catch {}

    // Enable Siri Remote touchpad directional D-Pad reports on Apple TV
    for controller in GCController.controllers() {
      controller.microGamepad?.reportsAbsoluteDpadValues = false
      controller.microGamepad?.allowsRotation = true
    }

    NotificationCenter.default.addObserver(
      forName: .GCControllerDidConnect,
      object: nil,
      queue: .main
    ) { notification in
      if let ctrl = notification.object as? GCController {
        ctrl.microGamepad?.reportsAbsoluteDpadValues = false
        ctrl.microGamepad?.allowsRotation = true
      }
    }

    return true
  }
}
