import Flutter

class HapticChannel {
    private let hapticManager = HapticManager()
    private var channel: FlutterMethodChannel?
    
    func register(with messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "haptic_channel",
            binaryMessenger: messenger
        )
        channel?.setMethodCallHandler { call, result in
            switch call.method {
            case "siren": self.hapticManager.playSirenHaptic()
            case "horn":  self.hapticManager.playHornHaptic()
            case "brake": self.hapticManager.playBrakeHaptic()
            case "name":  self.hapticManager.playNameCalledHaptic()
            default: break
            }
            result(nil)
        }
    }
}