import 'dart:async';
import 'sound_detector.dart';
import 'activity_service.dart';
import 'geofence_service.dart';
import 'notification.dart';
import 'tts.dart';
import 'haptic.dart';

class SoundManager {
  final SoundDetector _detector = SoundDetector();
  final ActivityService _activity = ActivityService();
  final GeofenceService _geofence = GeofenceService();
  final NotificationService _notification = NotificationService();
  final TtsService _tts = TtsService();
  final HapticService _haptic = HapticService();

  final Map<DetectedSound, DateTime> _lastDetectedAt = {};
  static const _cooldown = Duration(seconds: 3);

  StreamSubscription<DetectionEvent>? _soundSubscription;
  StreamSubscription<MotionState>? _motionSubscription;
  StreamSubscription<SensitivityLevel>? _sensitivitySubscription;

  bool _userEnabled = false;
  bool _micActive = false;

  void Function(DetectionEvent)? onDetected;

  Stream<DetectionEvent> get detectionStream => _detector.detectionStream;
  Stream<MotionState> get motionStream => _activity.motionStream;
  Stream<SensitivityLevel> get sensitivityStream => _geofence.sensitivityStream;

  MotionState get motionState => _activity.currentState;
  SensitivityLevel get sensitivityLevel => _geofence.currentLevel;

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
    _userEnabled = true;

    _startMic();

    await _activity.start();
    _motionSubscription = _activity.motionStream.listen((state) {
      if (state == MotionState.still) {
        _stopMic();
      } else {
        _startMic();
      }
    });

    await _geofence.start();
    _sensitivitySubscription = _geofence.sensitivityStream.listen((level) {
      _detector.setThreshold(level.threshold);
    });
    _detector.setThreshold(_geofence.currentLevel.threshold);
  }

  Future<void> stopMonitoring() async {
    _userEnabled = false;

    _motionSubscription?.cancel();
    _motionSubscription = null;
    _activity.stop();

    _sensitivitySubscription?.cancel();
    _sensitivitySubscription = null;
    _geofence.stop();

    _stopMic();
    _detector.setThreshold(SensitivityLevel.high.threshold);

    await _tts.stop();
  }

  bool _canTrigger(DetectedSound sound) {
    final last = _lastDetectedAt[sound];
    if (last == null) return true;
    return DateTime.now().difference(last) > _cooldown;
  }

  void _startMic() {
    if (_micActive || !_userEnabled) return;
    _micActive = true;
    _detector.start();

    _soundSubscription = _detector.detectionStream.listen((event) async {
      if (event.sound == DetectedSound.none) return;

      onDetected?.call(event);

      if (!_canTrigger(event.sound)) return;
      _lastDetectedAt[event.sound] = DateTime.now();

      _notification.showSoundAlert(event.sound);
      await _haptic.playPattern(event.sound);
      await _tts.speakUpdate(event.sound);
    });
  }

  void _stopMic() {
    if (!_micActive) return;
    _micActive = false;
    _soundSubscription?.cancel();
    _soundSubscription = null;
    _detector.stop();
  }

  void dispose() {
    stopMonitoring();
    _detector.dispose();
    _activity.dispose();
    _geofence.dispose();
    _tts.dispose();
  }
}
