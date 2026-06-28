package com.example.eartips

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.speech.tts.TextToSpeech
import java.util.Locale

class TtsManager(private val context: Context) : TextToSpeech.OnInitListener {

    private var tts: TextToSpeech? = null
    private var initialized = false
    private var pendingText: String? = null

    private val audioManager =
        context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var focusRequest: AudioFocusRequest? = null
    @Suppress("DEPRECATION")
    private var legacyFocusListener: AudioManager.OnAudioFocusChangeListener? = null

    private val audioAttrs = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build()

    // 즉시 리턴 — TTS 엔진은 백그라운드에서 onInit() 호출
    fun init() {
        if (tts != null) return
        tts = TextToSpeech(context, this)
    }

    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            val langResult = tts?.setLanguage(Locale.KOREAN)
            if (langResult == TextToSpeech.LANG_MISSING_DATA ||
                langResult == TextToSpeech.LANG_NOT_SUPPORTED
            ) {
                tts?.setLanguage(Locale.getDefault())
            }
            tts?.setSpeechRate(0.9f)
            tts?.setAudioAttributes(audioAttrs)
            initialized = true

            // init 이전에 speak() 요청이 왔으면 여기서 발화
            pendingText?.let {
                requestAudioFocus()
                tts?.speak(it, TextToSpeech.QUEUE_FLUSH, null, "eartips_utterance")
                pendingText = null
            }
        }
    }

    fun speak(text: String) {
        if (!initialized) {
            pendingText = text   // 준비될 때까지 대기
            return
        }
        requestAudioFocus()
        tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "eartips_utterance")
    }

    fun stop() {
        pendingText = null
        tts?.stop()
        abandonAudioFocus()
    }

    fun shutdown() {
        pendingText = null
        tts?.shutdown()
        tts = null
        initialized = false
        abandonAudioFocus()
    }

    @Suppress("DEPRECATION")
    private fun requestAudioFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setAudioAttributes(audioAttrs)
                .setAcceptsDelayedFocusGain(false)
                .build()
            audioManager.requestAudioFocus(focusRequest!!)
        } else {
            legacyFocusListener = AudioManager.OnAudioFocusChangeListener {}
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(
                legacyFocusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun abandonAudioFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            focusRequest = null
        } else {
            legacyFocusListener?.let { audioManager.abandonAudioFocus(it) }
            legacyFocusListener = null
        }
    }
}
