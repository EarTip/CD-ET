package com.example.eartips

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.plugin.common.MethodChannel

/**
 * 위젯 탭을 받는 화면 없는 중계 Activity.
 * - 엔진이 살아 있으면 Activity 없이 Dart에 토글만 전달
 * - 엔진이 없으면 투명 Activity로 엔진을 띄워 감지를 시작
 */
class WidgetTrampolineActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val engine = EngineProvider.peek()
        if (engine != null) {
            val prefs = getSharedPreferences(
                SoundWidgetProvider.PREFS_NAME, Context.MODE_PRIVATE
            )
            val start = !prefs.getBoolean(SoundWidgetProvider.KEY_IS_LISTENING, false)
            MethodChannel(engine.dartExecutor.binaryMessenger, EngineProvider.WIDGET_CHANNEL)
                .invokeMethod("toggle", if (start) "start" else "stop")
        } else {
            // 엔진이 죽어 있다는 건 감지도 꺼져 있다는 뜻이라, 저장된 상태와 무관하게 시작
            EngineProvider.pendingAction = "start"
            startActivity(
                Intent(this, WidgetLaunchActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }

        finish()
        overridePendingTransition(0, 0)
    }
}
