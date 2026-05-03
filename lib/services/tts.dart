import 'package:flutter_tts/flutter_tts.dart';
import 'sound_detector.dart';
import 'dart:io';
import 'audio_focus_service.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();
  final AudioFocusService _audioFocus = AudioFocusService();
  bool _initialized = false;
  VoidCallback? onSpeakCompleted;

  Future<void> init() async {
    await _audioFocus.init();
    await _tts.setLanguage('ko-KR');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);  //최댓값이 1.0
    await _tts.awaitSpeakCompletion(false);

    if (Platform.isIOS) {
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
          IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
        ],
        IosTextToSpeechAudioMode.voicePrompt,
      );
      await _tts.autoStopSharedSession(false);
    }

    if (Platform.isAndroid) {
      await _tts.setQueueMode(1);
    }

    _tts.setCompletionHandler(() async {
      await _audioFocus.releaseFocus();
      onSpeakCompleted?.call();
    });
    _initialized = true;
  }

  Future<void> speak(String message) async {
    if (!_initialized) await init();
    await _audioFocus.requestFocus();
    await _tts.stop();
    await _tts.speak(message);
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
    await _tts.stop();
    await _audioFocus.forceRelease();
  }

  void dispose() {
    _tts.stop();
    _audioFocus.dispose();
  }
}

typedef VoidCallback = void Function();
