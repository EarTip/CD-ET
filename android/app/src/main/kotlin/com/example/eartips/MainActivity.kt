package com.example.eartips

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private lateinit var hapticChannel: HapticChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        hapticChannel = HapticChannel(this)
        hapticChannel.register(flutterEngine)
    }
}