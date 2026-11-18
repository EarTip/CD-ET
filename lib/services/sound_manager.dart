import 'dart:async';
import 'package:flutter/foundation.dart';
import 'sound_detector.dart';
import 'activity_service.dart';
import 'geofence_service.dart';
import 'indoor_outdoor_service.dart';
import 'notification.dart';
import 'tts.dart';
import 'haptic.dart';
import 'settings_service.dart';
import 'earphone_service.dart';

class SoundManager {
  final SoundDetector _detector;
  final ActivityService _activity = ActivityService();
  final GeofenceService _geofence = GeofenceService();
  final NotificationService _notification = NotificationService();
  final TtsService _tts = TtsService();
  final HapticService _haptic = HapticService();
  final EarphoneService _earphone = EarphoneService();
  final SettingsService _settings = SettingsService.instance;

  late final IndoorOutdoorService _indoorOutdoor;

  final Map<DetectedSound, DateTime> _lastDetectedAt = {};
  static const _cooldown = Duration(seconds: 3);

  StreamSubscription<DetectionEvent>? _soundSubscription;
  StreamSubscription<MotionState>? _motionSubscription;
  StreamSubscription<SensitivityLevel>? _sensitivitySubscription;
  StreamSubscription<bool>? _earphoneSubscription;
  StreamSubscription<IndoorOutdoorState>? _indoorOutdoorSubscription;

  bool _userEnabled = false;
  bool _micActive = false;
  bool _isStill = false;
  MotionState _lastMotion = MotionState.unknown;

  void Function(DetectionEvent)? onDetected;

  /// horn/siren/brake 가 임계값 이상일 때 즉시 호출 (설정·쿨다운 적용 전 원시 감지)
  set onDangerDetected(DangerCallback? callback) => _detector.onDangerDetected = callback;

  /// multiLabel=true 면 model_multilabel.tflite 로 여러 소리를 동시에 감지
  SoundManager({bool multiLabel = false})
      : _detector = SoundDetector(multiLabel: multiLabel);

  Future<void> setMultiLabel(bool enabled) => _detector.setMultiLabel(enabled);

  Stream<DetectionEvent> get detectionStream => _detector.detectionStream;
  Stream<MotionState> get motionStream => _activity.motionStream;
  Stream<SensitivityLevel> get sensitivityStream => _geofence.sensitivityStream;
  Stream<bool> get earphoneStream => _earphone.connectionStream;
  Stream<IndoorOutdoorState> get indoorOutdoorStream => _indoorOutdoor.stateStream;

  MotionState get motionState => _activity.currentState;
  SensitivityLevel get sensitivityLevel => _geofence.currentLevel;
  bool get earphoneConnected => _earphone.isConnected;
  IndoorOutdoorState get indoorOutdoorState => _indoorOutdoor.state;
  bool get isOutdoor => _indoorOutdoor.isOutdoor;

  Future<void> init() async {
    _indoorOutdoor = IndoorOutdoorService(
      ambientProbe: _detector.probeTrafficAmbient,
    );
    await _settings.load();
    await _detector.init();
    await _notification.init();
    await _tts.init();
    _settings.addListener(_syncMic);
  }

  Future<void> startMonitoring() async {
    _userEnabled = true;
    _isStill = false;
    _lastMotion = MotionState.unknown;

    await _earphone.start();
    _earphoneSubscription = _earphone.connectionStream.listen((_) => _syncMic());

    _syncMic();

    await _activity.start();
    _motionSubscription = _activity.motionStream.listen((state) {
      final wasMoving = _lastMotion == MotionState.moving;
      _lastMotion = state;
      _isStill = state == MotionState.still;

      // still/unknown → moving 전환 시에만 check() 호출
      if (state == MotionState.moving && !wasMoving) {
        _indoorOutdoor.check();
      }
      _indoorOutdoor.setStationary(_isStill);

      _syncMic();
    });

    _indoorOutdoorSubscription = _indoorOutdoor.stateStream.listen((_) => _syncMic());

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

  /// 마이크가 켜져 있어야 하는 조건: 사용자 on · 이동 중 · 실외 · (이어폰 전용이면) 이어폰 연결
  /// 데모 모드에서는 이동 중 · 실외 조건을 건너뛴다.
  bool get _shouldListen {
    if (!_userEnabled) return false;
    if (!_settings.demoMode) {
      if (_isStill) return false;
      if (!_indoorOutdoor.isOutdoor) return false;
    }
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

  Future<void> _startMic() async {
    if (_micActive || !_userEnabled) return;
    _micActive = true;
    try {
      await _detector.start();
    } catch (e) {
      debugPrint('❌ 마이크 시작 실패: $e');
      _micActive = false;
      return;
    }
    if (!_micActive) {
      await _detector.stop();
      return;
    }

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

      // 녹음은 알림 중에도 계속되므로(audioInterruption=none) 자기 알림 소리를 감지하지 않게 막는다
      _detector.suppressFor(kAlertSuppress);

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

  Future<void> dispose() async {
    stopMonitoring();
    _settings.removeListener(_syncMic);
    _earphone.dispose();
    _indoorOutdoor.dispose();
    await _detector.dispose();
    _activity.dispose();
    _geofence.dispose();
    _tts.dispose();
  }
}
