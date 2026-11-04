package com.example.eartips

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * MainActivity와 위젯 전용 Activity가 하나의 FlutterEngine을 공유하기 위한 캐시.
 * 엔진을 따로 만들면 Dart 앱이 둘 떠서 마이크 감지가 중복 실행된다.
 */
object EngineProvider {
    const val ENGINE_ID = "eartips_engine"
    const val WIDGET_CHANNEL = "eartips/widget"

    /** 위젯으로 엔진을 새로 기동했을 때, Dart가 홈 화면 준비 후 가져가는 대기 액션 ("start") */
    @Volatile
    var pendingAction: String? = null

    fun peek(): FlutterEngine? = FlutterEngineCache.getInstance().get(ENGINE_ID)

    fun getOrCreate(context: Context): FlutterEngine {
        peek()?.let { return it }

        val appContext = context.applicationContext
        val engine = FlutterEngine(appContext)
        HapticChannel(appContext).register(engine)
        TtsChannel(appContext).register(engine)
        registerWidgetChannel(engine)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    private fun registerWidgetChannel(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, WIDGET_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumePendingAction" -> {
                        result.success(pendingAction)
                        pendingAction = null
                    }
                    // Dart가 감지 시작을 마쳤으니 위젯용 투명 Activity를 닫아도 된다
                    "readyToBackground" -> {
                        WidgetLaunchActivity.finishCurrent()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
