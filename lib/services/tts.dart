import 'package:flutter_tts/flutter_tts.dart';
import 'sound_detector.dart';

class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;

  Future<void> init() async {
    await _tts.setLanguage('ko-KR');
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.awaitSpeakCompletion(false);
    _initialized = true;
  }

  Future<void> speak(String message) async {
    if (!_initialized) await init();
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

  Future<void> stop() async => _tts.stop();

  void dispose() {
    _tts.stop();
  }
}