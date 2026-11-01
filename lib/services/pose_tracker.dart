import 'dart:async';
import 'package:sensors_plus/sensors_plus.dart';
import 'tdoa_analyzer.dart';

/// 방향 추정용 폰 자세 추적. 마이크가 켜져 있는 동안만 가속도계를 구독한다.
class PoseTracker {
  static const _samplingPeriod = Duration(milliseconds: 66); // ~15Hz
  static const _alpha          = 0.1; // 저역 통과 계수 — 걸음 흔들림을 걸러 중력 성분만 남김

  StreamSubscription<AccelerometerEvent>? _subscription;
  double _gx = 0, _gy = 0, _gz = 0;
  bool _hasSample = false;

  /// 최신 자세. 아직 센서 값이 없으면 null (방향은 unknown 처리됨).
  DevicePose? get current => _hasSample ? DevicePose.fromGravity(_gx, _gy, _gz) : null;

  void start() {
    if (_subscription != null) return;
    _hasSample = false;
    _subscription = accelerometerEventStream(
      samplingPeriod: _samplingPeriod,
    ).listen(_onAccel, onError: (_) {});
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _hasSample = false;
  }

  void _onAccel(AccelerometerEvent e) {
    if (!_hasSample) {
      _gx = e.x;
      _gy = e.y;
      _gz = e.z;
      _hasSample = true;
      return;
    }
    _gx += _alpha * (e.x - _gx);
    _gy += _alpha * (e.y - _gy);
    _gz += _alpha * (e.z - _gz);
  }
}
