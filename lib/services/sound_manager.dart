import 'dart:async';
import 'package:flutter/foundation.dart';
import 'sound_detector.dart';
import 'activity_service.dart';
import 'geofence_service.dart';
import 'indoor_outdoor_service.dart';
import 'notification.dart';
import 'tts.dart';
import 'haptic.dart';

class SoundManager {
  final SoundDetector      _detector     = SoundDetector();
  final ActivityService    _activity     = ActivityService();
  final GeofenceService    _geofence     = GeofenceService();
  final NotificationService _notification = NotificationService();
  final TtsService         _tts          = TtsService();
  final HapticService      _haptic       = HapticService();

  late final IndoorOutdoorService _indoorOutdoor;

  final Map<DetectedSound, DateTime> _lastDetectedAt = {};
  static const _cooldown = Duration(seconds: 3);

  StreamSubscription<DetectionEvent>?   _soundSubscription;
  StreamSubscription<MotionState>?      _motionSubscription;
  StreamSubscription<SensitivityLevel>? _sensitivitySubscription;
  StreamSubscription<IndoorOutdoorState>? _indoorOutdoorSubscription;

  bool _userEnabled = false;
  bool _micActive   = false;
  MotionState _lastMotion = MotionState.unknown;

  void Function(DetectionEvent)? onDetected;

  Stream<DetectionEvent>    get detectionStream      => _detector.detectionStream;
  Stream<MotionState>       get motionStream         => _activity.motionStream;
  Stream<SensitivityLevel>  get sensitivityStream    => _geofence.sensitivityStream;
  Stream<IndoorOutdoorState> get indoorOutdoorStream => _indoorOutdoor.stateStream;

  MotionState        get motionState       => _activity.currentState;
  SensitivityLevel   get sensitivityLevel  => _geofence.currentLevel;
  IndoorOutdoorState get indoorOutdoorState => _indoorOutdoor.state;
  bool               get isOutdoor         => _indoorOutdoor.isOutdoor;

  Future<void> init() async {
    _indoorOutdoor = IndoorOutdoorService(
      ambientProbe: _detector.probeTrafficAmbient,
    );
    await _detector.init();
    await _notification.init();
    await _tts.init();
  }

  Future<void> startMonitoring() async {
    _userEnabled  = true;
    _lastMotion   = MotionState.unknown;

    // 시작 시 안전 기본값: indoor (GPS/probe 결과 나올 때까지 마이크 OFF)
    // 걷기 감지 → check() → 실외 확정 후 마이크 ON
    _detector.setThreshold(SensitivityLevel.high.threshold);

    _activity.start();
    _motionSubscription = _activity.motionStream.listen(_onMotionChanged);

    // 실외 확정 후 마이크 켤 때만 시작 (실내에서 GPS 낭비 방지)
    _sensitivitySubscription = _geofence.sensitivityStream.listen((level) {
      _detector.setThreshold(level.threshold);
    });

    _indoorOutdoorSubscription = _indoorOutdoor.stateStream.listen((_) {
      _updateMicState();
    });
  }

  void _onMotionChanged(MotionState state) {
    final wasMoving = _lastMotion == MotionState.moving;
    _lastMotion = state;

    // still/unknown → moving 전환 시에만 check() 호출
    if (state == MotionState.moving && !wasMoving) {
      _indoorOutdoor.check();
    }
    _indoorOutdoor.setStationary(state == MotionState.still);

    _updateMicState();
  }

  void _updateMicState() {
    if (!_userEnabled) return;
    final motion   = _activity.currentState;
    final ioState  = _indoorOutdoor.state;

    if (motion != MotionState.moving || ioState != IndoorOutdoorState.outdoor) {
      _stopMic();
    } else {
      _startMic();
    }
  }

  Future<void> stopMonitoring() async {
    _userEnabled = false;
    _lastMotion  = MotionState.unknown;

    _motionSubscription?.cancel();
    _motionSubscription = null;
    _activity.stop();

    _sensitivitySubscription?.cancel();
    _sensitivitySubscription = null;
    _geofence.stop();

    _indoorOutdoorSubscription?.cancel();
    _indoorOutdoorSubscription = null;
    _indoorOutdoor.reset();

    _stopMic();
    _detector.setThreshold(SensitivityLevel.high.threshold);

    await _tts.stop();
  }

  bool _canTrigger(DetectedSound sound) {
    final last = _lastDetectedAt[sound];
    if (last == null) return true;
    return DateTime.now().difference(last) > _cooldown;
  }

  Future<void> _startMic() async {
    if (_micActive || !_userEnabled) return;
    _micActive = true;
    _geofence.start();
    await _detector.start();

    _soundSubscription = _detector.detectionStream.listen((event) async {
      if (event.sound == DetectedSound.none) return;

      onDetected?.call(event);

      if (!_canTrigger(event.sound)) {
        debugPrint('⏳ 쿨다운 중 — ${event.sound} 스킵');
        return;
      }
      _lastDetectedAt[event.sound] = DateTime.now();
      debugPrint('🔔 알림 트리거: ${event.sound}');

      _notification.showSoundAlert(event.sound);

      try {
        await _haptic.playPattern(event.sound);
        debugPrint('✅ 햅틱 완료');
      } catch (e) {
        debugPrint('❌ 햅틱 에러: $e');
      }

      try {
        await _tts.speakUpdate(event.sound);
        debugPrint('✅ TTS 호출 완료');
      } catch (e) {
        debugPrint('❌ TTS 에러: $e');
      }
    });
  }

  void _stopMic() {
    if (!_micActive) return;
    _micActive = false;
    _soundSubscription?.cancel();
    _soundSubscription = null;
    _detector.stop();
    _geofence.stop();
  }

  void dispose() {
    stopMonitoring();
    _detector.dispose();
    _activity.dispose();
    _geofence.dispose();
    _indoorOutdoor.dispose();
    _tts.dispose();
  }
}
