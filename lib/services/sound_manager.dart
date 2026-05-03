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

  final Map<DetectedSound, DateTime> _lastDetectedAt = {};
  static const _cooldown = Duration(seconds: 3);

  StreamSubscription<DetectedSound>? _subscription;
  Stream<DetectedSound> get detectionStream => _detector.detectionStream;

  void Function(DetectedSound)? onDetected;

  bool _canTrigger(DetectedSound sound) {
    final last = _lastDetectedAt[sound];
    if (last == null) return true;
    return DateTime.now().difference(last) > _cooldown;
  }

  Future<void> init() async {
    await _detector.init();
    await _notification.init();
    await _tts.init();
  }

  Future<void> startMonitoring() async {
    print('🟢 startMonitoring 호출됨');
    await _subscription?.cancel();
    await _detector.start();
    _subscription = _detector.detectionStream.listen((sound) async {
      if (sound == DetectedSound.none) return;

      print('🚨 감지: $sound');
      onDetected?.call(sound);
      if (!_canTrigger(sound)) {
        print('⏭ 쿨다운 중 — 스킵');
        return;
      }
      _lastDetectedAt[sound] = DateTime.now();

      _notification.showSoundAlert(sound);
      await _haptic.playPattern(sound);
      await _tts.speakUpdate(sound);
    });
  }

  Future<void> stopMonitoring() async {
    await _subscription?.cancel();
    _subscription = null;
    await _detector.stop();
    await _tts.stop();
  }

  void dispose() {
    stopMonitoring();
    _detector.dispose();
    _tts.dispose();
  }
}
