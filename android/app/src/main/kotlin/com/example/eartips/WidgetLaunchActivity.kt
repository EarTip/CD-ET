package com.example.eartips

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import java.lang.ref.WeakReference

/**
 * 앱이 꺼진 상태에서 위젯을 눌렀을 때 엔진을 띄우기 위한 투명 Activity.
 * 매니페스트에서 처음부터 투명 테마로 등록해 시스템이 스플래시를 그리지 않게 하고,
 * Dart가 감지 시작을 마치면(readyToBackground) 스스로 닫힌다. 엔진은 캐시에 남는다.
 */
class WidgetLaunchActivity : FlutterActivity() {

    companion object {
        /** Dart가 응답하지 않아도 투명 화면이 터치를 막은 채 남지 않도록 하는 안전장치 */
        private const val TIMEOUT_MS = 30_000L

        private var current: WeakReference<WidgetLaunchActivity>? = null

        fun finishCurrent() {
            current?.get()?.finish()
        }
    }

    private val handler = Handler(Looper.getMainLooper())

    override fun getCachedEngineId(): String = EngineProvider.ENGINE_ID

    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    override fun onCreate(savedInstanceState: Bundle?) {
        EngineProvider.getOrCreate(this)
        super.onCreate(savedInstanceState)
        current = WeakReference(this)

        // Flutter 화면(스플래시 등)은 그려지되 사용자에게는 보이지 않게 하고, 터치도 통과시킨다
        window.decorView.alpha = 0f
        window.addFlags(WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE)
        overridePendingTransition(0, 0)

        handler.postDelayed({ finish() }, TIMEOUT_MS)
    }

    override fun finish() {
        super.finish()
        overridePendingTransition(0, 0)
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        if (current?.get() === this) current = null
        super.onDestroy()
    }
}
