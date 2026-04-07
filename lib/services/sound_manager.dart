import 'dart:async';
import 'sound_detector.dart';
import 'notification.dart';
import 'tts.dart';
import 'haptic.dart';

class SoundManager {
  final SoundDetector _detector = SoundDetector();
  final NotificationService _notification = NotificationService();
  final TtsService _tts = TtsService();
  final HapticService _haptic = HapticService();

  StreamSubscription<DetectedSound>? _subscription;
  Stream<DetectedSound> get detectionStream => _detector.detectionStream;

  Future<void> init() async {
    await _detector.init();
    await _notification.init();
    await _tts.init();
  }

  void startMonitoring() {
    _detector.start();

    _subscription = _detector.detectionStream.listen((sound) {
      if (sound == DetectedSound.none) return;
      _notification.showSoundAlert(sound);
      _tts.speakUpdate(sound);
      _haptic.playPattern(sound);
    });
  }

  void stopMonitoring() {
    _subscription?.cancel();
    _detector.stop();
  }

  void dispose() {
    stopMonitoring();
    _detector.dispose();
    _tts.dispose();
  }
}