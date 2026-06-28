package com.example.eartips

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class TtsChannel(private val context: Context) {

    private val ttsManager = TtsManager(context)

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.example.eartips/tts"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> {
                    ttsManager.init()    // 백그라운드 초기화 시작
                    result.success(null) // 즉시 응답 → Flutter 블로킹 없음
                }
                "speak" -> {
                    val text = call.argument<String>("text") ?: run {
                        result.error("INVALID_ARGUMENT", "text is required", null)
                        return@setMethodCallHandler
                    }
                    ttsManager.speak(text)
                    result.success(null)
                }
                "stop" -> {
                    ttsManager.stop()
                    result.success(null)
                }
                "dispose" -> {
                    ttsManager.shutdown()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
