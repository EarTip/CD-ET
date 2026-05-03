import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

class HapticManager(private val context: Context) {

    private val vibrator: Vibrator by lazy {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            manager.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
    }

    // 🚨 사이렌: 파동형 반복 (올라갔다 내려오는 강도)
    fun playSiren() {
        // [대기, 진동, 대기, 진동, ...] 패턴 (ms 단위)
        val timings = longArrayOf(0, 300, 100, 300, 100, 300)
        val amplitudes = intArrayOf(0, 80, 0, 150, 0, 255)  // 점점 강해짐
        play(timings, amplitudes)
    }

    // 📯 경적: 짧고 강한 단타 2회
    fun playHorn() {
        val timings = longArrayOf(0, 120, 150, 120)
        val amplitudes = intArrayOf(0, 255, 0, 255)
        play(timings, amplitudes)
    }

    // 🛑 급브레이크: 강한 충격 후 점점 약해지는 여운
    fun playBrake() {
        val timings = longArrayOf(0, 80, 40, 60, 40, 40, 40, 20)
        val amplitudes = intArrayOf(0, 255, 0, 180, 0, 100, 0, 40)
        play(timings, amplitudes)
    }

    // 📢 이름 부르기: 부드럽고 여유있는 3회 탭
    fun playNameCalled() {
        val timings = longArrayOf(0, 80, 200, 80, 200, 80)
        val amplitudes = intArrayOf(0, 120, 0, 120, 0, 120)
        play(timings, amplitudes)
    }

    private fun play(timings: LongArray, amplitudes: IntArray) {
        if (!vibrator.hasVibrator()) return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // API 26+: amplitude(강도) 제어 가능
            val effect = VibrationEffect.createWaveform(timings, amplitudes, -1) // -1 = 반복 없음
            vibrator.vibrate(effect)
        } else {
            // API 26 미만: 강도 제어 불가, 타이밍만 사용
            @Suppress("DEPRECATION")
            vibrator.vibrate(timings, -1)
        }
    }

    fun cancel() {
        vibrator.cancel()
    }
}