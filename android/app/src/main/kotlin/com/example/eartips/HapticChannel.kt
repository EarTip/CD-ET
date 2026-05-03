import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.android.FlutterActivity

class HapticChannel(activity: FlutterActivity) {

    private val hapticManager = HapticManager(activity)

    companion object {
        const val CHANNEL_NAME = "haptic_channel"  // iOS와 동일한 채널명
    }

    fun register(flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "siren" -> hapticManager.playSiren()
                "horn"  -> hapticManager.playHorn()
                "brake" -> hapticManager.playBrake()
                "name"  -> hapticManager.playNameCalled()
                else    -> result.notImplemented()
            }
            result.success(null)
        }
    }
}