import 'dart:async';
import 'package:flutter/foundation.dart';
import 'sound_detector.dart';
import 'activity_service.dart';
import 'geofence_service.dart';
import 'notification.dart';
import 'tts.dart';
import 'haptic.dart';
import 'settings_service.dart';
import 'earphone_service.dart';

class SoundManager {
  final SoundDetector _detector = SoundDetector();
  final ActivityService _activity = ActivityService();
  final GeofenceService _geofence = GeofenceService();
  final NotificationService _notification = NotificationService();
  final TtsService _tts = TtsService();
  final HapticService _haptic = HapticService();
  final EarphoneService _earphone = EarphoneService();
  final SettingsService _settings = SettingsService.instance;

  final Map<DetectedSound, DateTime> _lastDetectedAt = {};
  static const _cooldown = Duration(seconds: 3);

  StreamSubscription<DetectionEvent>? _soundSubscription;
  StreamSubscription<MotionState>? _motionSubscription;
  StreamSubscription<SensitivityLevel>? _sensitivitySubscription;
  StreamSubscription<bool>? _earphoneSubscription;

  bool _userEnabled = false;
  bool _micActive = false;
  bool _isStill = false;

  void Function(DetectionEvent)? onDetected;

  Stream<DetectionEvent> get detectionStream => _detector.detectionStream;
  Stream<MotionState> get motionStream => _activity.motionStream;
  Stream<SensitivityLevel> get sensitivityStream => _geofence.sensitivityStream;
  Stream<bool> get earphoneStream => _earphone.connectionStream;

  MotionState get motionState => _activity.currentState;
  SensitivityLevel get sensitivityLevel => _geofence.currentLevel;
  bool get earphoneConnected => _earphone.isConnected;

  Future<void> init() async {
    await _settings.load();
    await _detector.init();
    await _notification.init();
    await _tts.init();
    _settings.addListener(_syncMic);
  }

  Future<void> startMonitoring() async {
    _userEnabled = true;
    _isStill = false;

    await _earphone.start();
    _earphoneSubscription = _earphone.connectionStream.listen((_) => _syncMic());

    _syncMic();

    await _activity.start();
    _motionSubscription = _activity.motionStream.listen((state) {
      _isStill = state == MotionState.still;
      _syncMic();
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

    _earphoneSubscription?.cancel();
    _earphoneSubscription = null;
    _earphone.stop();

    _stopMic();
    _detector.setThreshold(SensitivityLevel.high.threshold);

    await _tts.stop();
  }

  bool _canTrigger(DetectedSound sound) {
    final last = _lastDetectedAt[sound];
    if (last == null) return true;
    return DateTime.now().difference(last) > _cooldown;
  }

  /// 마이크가 켜져 있어야 하는 조건: 사용자 on · 이동 중 · (이어폰 전용이면) 이어폰 연결
  bool get _shouldListen {
    if (!_userEnabled || _isStill) return false;
    if (_settings.earphoneOnly && !_earphone.isConnected) return false;
    return true;
  }

  void _syncMic() {
    if (_shouldListen) {
      _startMic();
    } else {
      _stopMic();
    }
  }

  void _startMic() {
    if (_micActive || !_userEnabled) return;
    _micActive = true;
    _detector.start();

    _soundSubscription = _detector.detectionStream.listen((event) async {
      if (event.sound == DetectedSound.none) return;

      if (!_settings.isSoundEnabled(event.sound)) {
        debugPrint('🔕 설정에서 꺼짐 — ${event.sound} 스킵');
        return;
      }

      onDetected?.call(event);

      if (!_canTrigger(event.sound)) {
        debugPrint('⏳ 쿨다운 중 — ${event.sound} 스킵');
        return;
      }
      _lastDetectedAt[event.sound] = DateTime.now();

      final channels = _settings.alertChannels;
      debugPrint('🔔 알림 트리거: ${event.sound} (채널: ${channels.map((c) => c.label).join(', ')})');

      if (channels.contains(AlertChannel.preview)) {
        _notification.showSoundAlert(event.sound);
      }

      if (channels.contains(AlertChannel.haptic)) {
        try {
          await _haptic.playPattern(event.sound);
          debugPrint('✅ 햅틱 완료');
        } catch (e) {
          debugPrint('❌ 햅틱 에러: $e');
        }
      }

      if (channels.contains(AlertChannel.voice)) {
        try {
          await _tts.speakUpdate(event.sound);
          debugPrint('✅ TTS 호출 완료');
        } catch (e) {
          debugPrint('❌ TTS 에러: $e');
        }
      }
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
    _settings.removeListener(_syncMic);
    _earphone.dispose();
    _detector.dispose();
    _activity.dispose();
    _geofence.dispose();
    _tts.dispose();
  }
}
