import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'sound_detector.dart';
import 'audio_focus_service.dart';

class TtsService {
  static const MethodChannel _androidChannel =
      MethodChannel('com.example.eartips/tts');

  final FlutterTts _tts = FlutterTts();
  final AudioFocusService _audioFocus = AudioFocusService();
  bool _initialized = false;
  VoidCallback? onSpeakCompleted;

  Future<void> init() async {
    if (Platform.isAndroid) {
      await _androidChannel.invokeMethod('init');
    } else {
      await _audioFocus.init();
      await _tts.setLanguage('ko-KR');
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.awaitSpeakCompletion(false);

      if (Platform.isIOS) {
        await _tts.setSharedInstance(true);
        await _tts.autoStopSharedSession(false);
      }

      _tts.setStartHandler(() {
        debugPrint('🔊 TTS 재생 시작됨');
      });

      _tts.setCompletionHandler(() async {
        debugPrint('🔊 TTS 재생 완료');
        await _audioFocus.releaseFocus();
        onSpeakCompleted?.call();
      });

      _tts.setErrorHandler((msg) {
        debugPrint('❌ TTS 에러: $msg');
      });

      _tts.setCancelHandler(() {
        debugPrint('⚠️ TTS 취소됨');
      });

      final languages = await _tts.getLanguages;
      debugPrint('🌐 TTS 사용 가능 언어: $languages');
      final isKoAvailable = await _tts.isLanguageAvailable('ko-KR');
      debugPrint('🇰🇷 ko-KR 사용 가능: $isKoAvailable');
    }
    _initialized = true;
  }

  Future<void> speak(String message) async {
    if (!_initialized) await init();

    if (Platform.isAndroid) {
      await _androidChannel.invokeMethod('speak', {'text': message});
    } else {
      debugPrint('🔊 TTS speak 호출: "$message"');
      await _audioFocus.requestFocus();
      final result = await _tts.speak(message);
      debugPrint('🔊 TTS speak 결과: $result (1=성공, 0=실패)');
    }
  }

  Future<void> speakUpdate(DetectedSound sound) async {
    switch (sound) {
      case DetectedSound.horn:
        await speak('경적이 감지되었습니다');
      case DetectedSound.siren:
        await speak('사이렌이 감지되었습니다');
      case DetectedSound.brake:
        await speak('급정거가 감지되었습니다');
      case DetectedSound.none:
        break;
    }
  }

  Future<void> stop() async {
    if (Platform.isAndroid) {
      await _androidChannel.invokeMethod('stop');
    } else {
      await _tts.stop();
      await _audioFocus.forceRelease();
    }
  }

  void dispose() {
    if (Platform.isAndroid) {
      _androidChannel.invokeMethod('dispose');
    } else {
      _tts.stop();
      _audioFocus.dispose();
    }
  }
}
