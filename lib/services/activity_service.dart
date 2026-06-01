import 'dart:async';
import 'dart:math';
import 'package:sensors_plus/sensors_plus.dart';

enum MotionState { moving, still, unknown }

class ActivityService {
  // 20Hz 샘플링, 1초 윈도우
  static const _samplingPeriod    = Duration(milliseconds: 50);
  static const _windowSize        = 20;   // 20 samples = 1초
  static const _movingThreshold   = 0.05; // 분산 이 값 초과 → 이동 중
  static const _stillThreshold    = 0.02; // 분산 이 값 미만 → 정지

  final _motionController = StreamController<MotionState>.broadcast();
  StreamSubscription? _subscription;
  final List<double> _magBuffer = [];

  MotionState _currentState = MotionState.unknown;

  Stream<MotionState> get motionStream => _motionController.stream;
  MotionState get currentState => _currentState;

  Future<void> start() async {
    _magBuffer.clear();
    _currentState = MotionState.unknown;

    _subscription = userAccelerometerEventStream(
      samplingPeriod: _samplingPeriod,
    ).listen(_onAccel, onError: (_) {});
  }

  void _onAccel(UserAccelerometerEvent e) {
    // 선형 가속도 크기 (중력 제거됨)
    final mag = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    _magBuffer.add(mag);
    if (_magBuffer.length > _windowSize) _magBuffer.removeAt(0);
    if (_magBuffer.length < _windowSize) return; // 윈도우 채울 때까지 대기

    final v = _variance(_magBuffer);

    // 히스테리시스: moving → still 전환은 낮은 임계값, still → moving은 높은 임계값
    final next = switch (_currentState) {
      MotionState.moving  => v < _stillThreshold   ? MotionState.still  : MotionState.moving,
      MotionState.still   => v > _movingThreshold  ? MotionState.moving : MotionState.still,
      MotionState.unknown => v > _movingThreshold  ? MotionState.moving
                           : v < _stillThreshold   ? MotionState.still
                           : MotionState.unknown,
    };

    if (next != _currentState) {
      _currentState = next;
      _motionController.add(next);
    }
  }

  double _variance(List<double> data) {
    final mean = data.reduce((a, b) => a + b) / data.length;
    return data.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) / data.length;
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _magBuffer.clear();
    _currentState = MotionState.unknown;
  }

  void dispose() {
    stop();
    _motionController.close();
  }
}
