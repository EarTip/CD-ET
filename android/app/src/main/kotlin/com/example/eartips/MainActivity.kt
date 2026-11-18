package com.example.eartips

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun getCachedEngineId(): String = EngineProvider.ENGINE_ID

    override fun onCreate(savedInstanceState: Bundle?) {
        // 캐시된 엔진이 없으면(앱 첫 실행) 여기서 만든다
        EngineProvider.getOrCreate(this)
        super.onCreate(savedInstanceState)
    }
}
