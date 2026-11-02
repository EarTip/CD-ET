import 'dart:math';

import 'package:eartips/services/tdoa_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

const _fs = 16000.0;
const _windowSize = 15600;

/// 경적과 비슷한 배음 신호 (기본음 420 Hz + 배음 5개). 연속 함수라 소수 지연도 정확히 만들 수 있다.
double _horn(double t) {
  double v = 0;
  for (int k = 1; k <= 6; k++) {
    v += sin(2 * pi * 420 * k * t + k * 0.7) / k;
  }
  return v * 0.2;
}

/// 300 Hz–3 kHz 대역의 넓은 잡음 (랜덤 주파수 사인 120개 합)
double Function(double) _bandNoise(int seed) {
  final rnd = Random(seed);
  final freqs = List.generate(120, (_) => 300 + rnd.nextDouble() * 2700);
  final phases = List.generate(120, (_) => rnd.nextDouble() * 2 * pi);
  return (t) {
    double v = 0;
    for (int i = 0; i < freqs.length; i++) {
      v += sin(2 * pi * freqs[i] * t + phases[i]);
    }
    return v * 0.02;
  };
}

/// 소리 [source]가 ch1(상단)에 먼저 오고 ch2(하단)에 [delay] 샘플 늦게 도착하는 스테레오 창.
/// [active]가 주어지면 그 샘플 구간에서만 소리가 난다. 두 채널에 독립 잡음을 더한다.
(List<double>, List<double>) _stereo(
  double Function(double) source,
  double delay, {
  double noise = 0.01,
  int seed = 1,
  (int, int)? active,
}) {
  final rnd = Random(seed);
  double gauss() => sqrt(-2 * log(rnd.nextDouble() + 1e-12)) * cos(2 * pi * rnd.nextDouble());
  final ch1 = <double>[], ch2 = <double>[];
  for (int n = 0; n < _windowSize; n++) {
    final on = active == null || (n >= active.$1 && n < active.$2);
    ch1.add((on ? source(n / _fs) : 0) + noise * gauss());
    ch2.add((on ? source((n - delay) / _fs) : 0) + noise * gauss());
  }
  return (ch1, ch2);
}

/// 폰 축 앙각 [elevationDeg]로 화면이 위를 향한 자세
DevicePose _pose(double elevationDeg, {bool screenUp = true}) {
  final e = elevationDeg * pi / 180;
  return DevicePose.fromGravity(0, 9.8 * sin(e), (screenUp ? 1 : -1) * 9.8 * cos(e));
}

/// 수평 방위각 [azimuthDeg] 소리가 자세 [elevationDeg]에서 만드는 지연 (샘플)
double _lagFor(double azimuthDeg, double elevationDeg) {
  final tilt = (90 - elevationDeg) * pi / 180;
  final sinTheta = sin(tilt) * cos(azimuthDeg * pi / 180);
  return sinTheta * 0.15 / 343 * _fs;
}

void main() {
  group('estimateBlocks (GCC-PHAT 지연 추정)', () {
    test('정수 지연 +5 샘플', () {
      final (a, b) = _stereo(_horn, 5);
      final lag = TdoaAnalyzer.medianLag(TdoaAnalyzer.selectBlocks(TdoaAnalyzer.estimateBlocks(a, b)));
      expect(lag, closeTo(5, 0.3));
    });

    test('음수 지연 -4 샘플', () {
      final (a, b) = _stereo(_horn, -4);
      final lag = TdoaAnalyzer.medianLag(TdoaAnalyzer.selectBlocks(TdoaAnalyzer.estimateBlocks(a, b)));
      expect(lag, closeTo(-4, 0.3));
    });

    test('소수 지연 2.5 샘플 (포물선 보간)', () {
      final (a, b) = _stereo(_bandNoise(7), 2.5);
      final lag = TdoaAnalyzer.medianLag(TdoaAnalyzer.selectBlocks(TdoaAnalyzer.estimateBlocks(a, b)));
      expect(lag, closeTo(2.5, 0.35));
    });

    test('순수 지연이면 신뢰도가 높다', () {
      final (a, b) = _stereo(_bandNoise(3), 3, noise: 0.001);
      final blocks = TdoaAnalyzer.estimateBlocks(a, b);
      expect(blocks, hasLength(_windowSize ~/ 2048));
      for (final blk in blocks) {
        expect(blk.confidence, greaterThan(0.5));
      }
    });

    test('서로 무관한 잡음은 신뢰도 하한을 넘지 못한다', () {
      final (a, _) = _stereo(_bandNoise(11), 0, noise: 0, seed: 1);
      final (_, b) = _stereo(_bandNoise(12), 0, noise: 0, seed: 2);
      expect(TdoaAnalyzer.selectBlocks(TdoaAnalyzer.estimateBlocks(a, b)), isEmpty);
    });
  });

  group('analyze (자세 보정 + 블록 투표)', () {
    final walking = _pose(45); // 화면 보며 걷는 자세 (약 45°)

    test('정면 소리 → front', () {
      final (a, b) = _stereo(_horn, _lagFor(0, 45));
      expect(TdoaAnalyzer.analyze(a, b, pose: walking), SoundDirection.front);
    });

    test('후방 소리 → behind', () {
      final (a, b) = _stereo(_horn, _lagFor(180, 45));
      expect(TdoaAnalyzer.analyze(a, b, pose: walking), SoundDirection.behind);
    });

    // 측면 판정은 비활성: 앞뒤를 가를 수 없는 측면 소리는 unknown (틀린 방향보다 생략)
    // test('측면 소리 → side', () {
    //   final (a, b) = _stereo(_bandNoise(5), _lagFor(90, 45));
    //   expect(TdoaAnalyzer.analyze(a, b, pose: walking), SoundDirection.side);
    // });
    test('측면 소리 → unknown (측면 판정 비활성)', () {
      final (a, b) = _stereo(_bandNoise(5), _lagFor(90, 45));
      expect(TdoaAnalyzer.analyze(a, b, pose: walking), SoundDirection.unknown);
    });

    test('기울기 보정: 45° 자세에서 방위각 60° 소리는 front (보정 전에는 측면으로 빠지던 경우)', () {
      // 폰 축 기준 θ ≈ 20.7° — 예전 25° 임계값이면 side
      final (a, b) = _stereo(_bandNoise(9), _lagFor(60, 45));
      expect(TdoaAnalyzer.analyze(a, b, pose: walking), SoundDirection.front);
    });

    test('경적이 창의 일부(뒤쪽 30%)에만 있어도 front', () {
      final (a, b) = _stereo(_horn, _lagFor(0, 45), active: (11000, _windowSize));
      expect(TdoaAnalyzer.analyze(a, b, pose: walking), SoundDirection.front);
    });

    test('channelSign = -1 이면 방향이 뒤집힌다', () {
      addTearDown(() => TdoaAnalyzer.channelSign = 1);
      TdoaAnalyzer.channelSign = -1;
      final (a, b) = _stereo(_horn, _lagFor(0, 45));
      expect(TdoaAnalyzer.analyze(a, b, pose: walking), SoundDirection.behind);
    });
  });

  group('analyze가 unknown을 내는 경우', () {
    final (front1, front2) = _stereo(_horn, 4);

    test('자세 정보 없음', () {
      expect(TdoaAnalyzer.analyze(front1, front2), SoundDirection.unknown);
    });

    test('세워 든 자세 (주머니 포함)', () {
      expect(TdoaAnalyzer.analyze(front1, front2, pose: _pose(85)), SoundDirection.unknown);
    });

    test('화면이 아래를 향함', () {
      expect(TdoaAnalyzer.analyze(front1, front2, pose: _pose(45, screenUp: false)), SoundDirection.unknown);
    });

    test('상단이 아래를 향함 (뒤집힌 자세)', () {
      expect(TdoaAnalyzer.analyze(front1, front2, pose: _pose(-30)), SoundDirection.unknown);
    });

    test('두 채널이 동일 (모노 fallback·가짜 스테레오)', () {
      expect(TdoaAnalyzer.analyze(front1, List.of(front1), pose: _pose(45)), SoundDirection.unknown);
    });

    test('서로 무관한 잡음', () {
      final (a, _) = _stereo(_bandNoise(21), 0, noise: 0, seed: 1);
      final (_, b) = _stereo(_bandNoise(22), 0, noise: 0, seed: 2);
      expect(TdoaAnalyzer.analyze(a, b, pose: _pose(45)), SoundDirection.unknown);
    });

    test('블록 하나보다 짧은 입력', () {
      expect(TdoaAnalyzer.analyze(front1.sublist(0, 1000), front2.sublist(0, 1000), pose: _pose(45)),
          SoundDirection.unknown);
    });
  });

  group('DevicePose', () {
    test('세워 들기: 앙각 90°, 기울기 0°', () {
      final p = DevicePose.fromGravity(0, 9.8, 0);
      expect(p.axisElevationDeg, closeTo(90, 1e-6));
      expect(p.tiltFromVerticalDeg, closeTo(0, 1e-6));
      expect(p.canEstimateDirection, isFalse);
    });

    test('화면 보며 걷기 (45°)는 방향 추정 가능', () {
      expect(_pose(45).canEstimateDirection, isTrue);
    });

    test('책상 위에 화면이 위로 놓임 (수평)은 방향 추정 가능', () {
      expect(DevicePose.fromGravity(0, 0, 9.8).canEstimateDirection, isTrue);
    });
  });
}
