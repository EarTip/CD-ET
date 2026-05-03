import Flutter

class HapticChannel {
    private let hapticManager = HapticManager()
    
    func register(with controller: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: "haptic_channel",
            binaryMessenger: controller.binaryMessenger
        )
        channel.setMethodCallHandler { call, result in
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