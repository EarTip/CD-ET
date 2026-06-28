package com.example.eartips

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class HapticChannel(private val context: Context) {

    private val hapticManager = HapticManager(context)

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "haptic_channel"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "siren" -> {
                    hapticManager.playSiren()
                    result.success(null)
                }
                "horn" -> {
                    hapticManager.playHorn()
                    result.success(null)
                }
                "brake" -> {
                    hapticManager.playBrake()
                    result.success(null)
                }
                "name" -> {
                    hapticManager.playNameCalled()
                    result.success(null)
                }
                "cancel" -> {
                    hapticManager.cancel()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}