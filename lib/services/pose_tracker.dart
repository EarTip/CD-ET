import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'tdoa_analyzer.dart';

/// 방향 추정용 폰 자세 추적. 마이크가 켜져 있는 동안만 가속도계를 구독한다.
class PoseTracker {
  static const _samplingPeriod = Duration(milliseconds: 66); // ~15Hz
  static const _alpha          = 0.1; // 저역 통과 계수 — 걸음 흔들림을 걸러 중력 성분만 남김

  /// 마지막 샘플이 이보다 오래됐으면 자세를 믿지 않는다 (센서가 끊긴 채 옛 자세로 방향이 붙는 것을 막음).
  /// 샘플 간격(~66ms)보다 충분히 크게 둔다.
  static const maxSampleAge = Duration(seconds: 1);

  /// 시스템 시계 변경에 영향받지 않도록 단조 증가 시계를 쓴다.
  static final Stopwatch _monotonic = Stopwatch()..start();

  PoseTracker({Duration Function()? uptime}) : _uptime = uptime ?? (() => _monotonic.elapsed);

  final Duration Function() _uptime;

  StreamSubscription<AccelerometerEvent>? _subscription;
  double _gx = 0, _gy = 0, _gz = 0;
  bool _hasSample = false;
  Duration _lastSampleAt = Duration.zero;

  /// 최신 자세. 센서 값이 아직 없거나 [maxSampleAge]보다 오래됐으면 null (방향은 unknown 처리됨).
  DevicePose? get current {
    if (!_hasSample || _isStale) return null;
    return DevicePose.fromGravity(_gx, _gy, _gz);
  }

  bool get _isStale => _uptime() - _lastSampleAt > maxSampleAge;

  void start() {
    if (_subscription != null) return;
    _hasSample = false;
    _subscription = accelerometerEventStream(
      samplingPeriod: _samplingPeriod,
    ).listen((e) => _applySample(e.x, e.y, e.z), onError: (_) {});
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _hasSample = false;
  }

  /// 센서 이벤트를 거치지 않고 샘플을 넣는다 (테스트용).
  @visibleForTesting
  void addSample(double x, double y, double z) => _applySample(x, y, z);

  void _applySample(double x, double y, double z) {
    // 오래 끊겼다가 다시 들어온 첫 샘플이면 옛 값에서 서서히 이어가지 않고 새로 시작한다.
    if (_hasSample && _isStale) _hasSample = false;

    _lastSampleAt = _uptime();
    if (!_hasSample) {
      _gx = x;
      _gy = y;
      _gz = z;
      _hasSample = true;
      return;
    }
    _gx += _alpha * (x - _gx);
    _gy += _alpha * (y - _gy);
    _gz += _alpha * (z - _gz);
  }
}
