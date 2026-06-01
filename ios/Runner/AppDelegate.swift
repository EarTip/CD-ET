import UIKit
import Flutter
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let hapticChannel = HapticChannel()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playAndRecord,
      options: [.mixWithOthers, .duckOthers, .allowBluetoothA2DP])
    try? session.setActive(true)

    GeneratedPluginRegistrant.register(with: self)
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    if let controller = window?.rootViewController as? FlutterViewController {
      hapticChannel.register(with: controller)
      setupInterruptionObserver()
    }

    return result
  }

  private func setupInterruptionObserver() {
    NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: nil,
      queue: .main
    ) { notification in
      guard
        let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: typeValue)
      else { return }

      if type == .ended {
        try? AVAudioSession.sharedInstance().setActive(true)
      }
    }
  }
}