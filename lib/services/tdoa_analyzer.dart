import 'dart:math';
import 'dart:typed_data';

// ──────────────────────────────────────────────
// 공통 도메인 모델
// ──────────────────────────────────────────────

enum DetectedSound { horn, siren, brake, name, none }

enum SoundDirection { front, behind, side, unknown }

extension SoundDirectionInfo on SoundDirection {
  String get label => switch (this) {
        SoundDirection.front   => '정면',
        SoundDirection.behind  => '후방',
        SoundDirection.side    => '측면',
        SoundDirection.unknown => '방향 미상',
      };
}

class DetectionEvent {
  final DetectedSound sound;
  final SoundDirection direction;
  const DetectionEvent(this.sound, this.direction);
}

/// SoundDetector가 마이크에서 받은 원본 스테레오(또는 모노) PCM 청크.
/// YAMNet 전용 윈도잉과 독립적으로, 다른 감지기(NameCallDetector 등)가
/// 같은 마이크 스트림을 공유해서 쓸 수 있도록 노출하는 값 타입.
class RawAudioChunk {
  final Float32List left;
  final Float32List right; // isStereo == false면 left와 동일한 값
  final bool isStereo;
  const RawAudioChunk(this.left, this.right, this.isStereo);
}

// ──────────────────────────────────────────────
// TDOA 분석기 (GCC 기반 시간영역 교차상관)
// ──────────────────────────────────────────────

class TdoaAnalyzer {
  // 16kHz 샘플링, 15cm 마이크 간격 기준
  // 최대 TDOA = 0.15m / 343 m/s ≈ 0.44ms ≈ 7 samples
  static const _sampleRate       = 16000.0;
  static const _micDistanceM     = 0.15;   // 마이크 간격 (m)
  static const _speedOfSound     = 343.0;  // 음속 (m/s)
  static const _maxLag           = 10;     // 탐색 최대 lag (samples)
  static const _minConfidence    = 0.15;   // 유효 신뢰도 하한
  static const _dirThresholdDeg  = 25.0;   // 정면/후방 판단 각도 (°)

  /// ch1 = 상단 마이크, ch2 = 하단 마이크 (스테레오 L/R)
  static SoundDirection analyze(List<double> ch1, List<double> ch2) {
    if (ch1.length < _maxLag * 4 || ch2.length < _maxLag * 4) {
      return SoundDirection.unknown;
    }

    final (lag, confidence) = _xcorr(ch1, ch2);

    if (confidence < _minConfidence) return SoundDirection.unknown;

    // lag = 0 이고 신뢰도가 매우 높으면 두 채널이 동일 (모노 기기)
    if (lag == 0 && confidence > 0.95) return SoundDirection.unknown;

    // TDOA → 입사각 추정
    final tdoaSec  = lag / _sampleRate;
    final sinTheta = (tdoaSec * _speedOfSound / _micDistanceM).clamp(-1.0, 1.0);
    final thetaDeg = asin(sinTheta) * 180 / pi;

    if (thetaDeg.abs() < _dirThresholdDeg) return SoundDirection.side;
    return thetaDeg > 0 ? SoundDirection.front : SoundDirection.behind;
  }

  /// 정규화된 시간영역 교차상관 (±_maxLag 탐색)
  /// 반환: (최적 lag, 신뢰도 0~1)
  static (int, double) _xcorr(List<double> x1, List<double> x2) {
    final n = min(x1.length, x2.length);
    // 에지 효과를 줄이기 위해 중간 50% 구간만 사용
    final s = n ~/ 4;
    final e = n - s;

    double e1 = 0, e2 = 0;
    for (int i = s; i < e; i++) {
      e1 += x1[i] * x1[i];
      e2 += x2[i] * x2[i];
    }
    if (e1 < 1e-8 || e2 < 1e-8) return (0, 0.0); // 무음 구간

    final norm = sqrt(e1 * e2);
    int bestLag = 0;
    double bestCorr = double.negativeInfinity;

    for (int lag = -_maxLag; lag <= _maxLag; lag++) {
      double corr = 0;
      for (int i = s; i < e; i++) {
        final j = i + lag;
        if (j >= s && j < e) corr += x1[i] * x2[j];
      }
      if (corr > bestCorr) {
        bestCorr = corr;
        bestLag = lag;
      }
    }

    return (bestLag, (bestCorr / norm).clamp(0.0, 1.0));
  }
}
