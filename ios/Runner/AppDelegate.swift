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
    do {
      try session.setCategory(.playAndRecord,
        options: [.mixWithOthers, .duckOthers, .allowBluetoothA2DP])
    } catch {
      try? session.setCategory(.playAndRecord,
        options: [.mixWithOthers, .duckOthers, .allowBluetooth])
    }
    try? session.setActive(true)
    try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)

    GeneratedPluginRegistrant.register(with: self)
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    setupInterruptionObserver()

    if let registrar = self.registrar(forPlugin: "HapticChannel") {
      hapticChannel.register(with: registrar.messenger())
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