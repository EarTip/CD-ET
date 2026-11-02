import 'dart:math';
import 'dart:typed_data';

// ──────────────────────────────────────────────
// 공통 도메인 모델
// ──────────────────────────────────────────────

enum DetectedSound { horn, siren, brake, bicycle, none }

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

// ──────────────────────────────────────────────
// 폰 자세 (중력 벡터 기반)
// ──────────────────────────────────────────────

/// 방향을 낼 수 있는 자세인지 판단하기 위한 폰 자세.
/// 상·하단 마이크 한 쌍은 "폰 길이 축 기준 각도"만 잴 수 있어서, 폰 축의 수평 투영이
/// 진행 방향과 같은 자세(화면을 보며 들고 걷기)에서만 그 각도를 전/후방으로 해석할 수 있다.
class DevicePose {
  /// 폰 길이 축(상단 방향)이 수평면 위로 올라간 각도.
  /// +90° = 똑바로 세움, 0° = 수평, 음수 = 상단이 아래를 향함
  final double axisElevationDeg;

  /// 화면이 위쪽을 향하는지 (화면을 보며 걷는 자세의 전제)
  final bool screenUp;

  const DevicePose({required this.axisElevationDeg, required this.screenUp});

  /// 가속도계(중력 포함) 값으로 자세를 만든다. Android 좌표계 기준:
  /// 세워 들면 y ≈ +9.8, 화면이 하늘을 보면 z ≈ +9.8.
  factory DevicePose.fromGravity(double x, double y, double z) {
    final norm = sqrt(x * x + y * y + z * z);
    if (norm < 1e-6) return const DevicePose(axisElevationDeg: 90, screenUp: false);
    return DevicePose(
      axisElevationDeg: asin((y / norm).clamp(-1.0, 1.0)) * 180 / pi,
      screenUp: z > 0,
    );
  }

  /// 폰 축이 수직에서 기울어진 각도 t (sin θ = sin t · cos φ 의 t)
  double get tiltFromVerticalDeg => 90 - axisElevationDeg;

  /// "화면을 보며 들고 걷는" 자세일 때만 폰 축의 수평 투영 = 진행 방향으로 본다.
  /// 세워 들거나(기울기 부족) 주머니(대개 세워짐/뒤집힘)·화면이 아래를 향하면 false.
  bool get canEstimateDirection =>
      screenUp &&
      axisElevationDeg >= TdoaAnalyzer.minAxisElevationDeg &&
      axisElevationDeg <= TdoaAnalyzer.maxAxisElevationDeg;
}

// ──────────────────────────────────────────────
// TDOA 분석기 (블록 단위 대역 제한 GCC-PHAT)
// ──────────────────────────────────────────────

/// 블록 하나의 지연 추정 결과
class BlockEstimate {
  /// 지연 (샘플, 보간값). 양수 = ch1(상단)에 먼저 도착
  final double lag;

  /// GCC-PHAT 피크 선명도 (0~1, 완전한 순수 지연이면 1)
  final double confidence;

  /// 목표 대역(300 Hz–3 kHz) 에너지
  final double bandEnergy;

  const BlockEstimate(this.lag, this.confidence, this.bandEnergy);
}

class TdoaAnalyzer {
  // 16kHz 샘플링, 15cm 마이크 간격 기준
  // 최대 TDOA = 0.15m / 343 m/s ≈ 0.44ms ≈ 7 samples
  static const _sampleRate       = 16000.0;
  static const _micDistanceM     = 0.15;   // 마이크 간격 (m)
  static const _speedOfSound     = 343.0;  // 음속 (m/s)
  static const _maxLag           = 10;     // 탐색 최대 lag (samples, 간격 오차 여유 포함)

  static const _blockSize        = 2048;   // 블록 길이 (15600 샘플 창 → 7블록)
  static const _fftSize          = 4096;   // 순환 상관 방지용 zero-padding
  static const _bandLowHz        = 300.0;  // 경적·사이렌 대역
  static const _bandHighHz       = 3000.0;
  /// PHAT-β 가중 지수. 1이면 순수 PHAT(모든 주파수 동일 가중)인데, 경적처럼 에너지가
  /// 배음 몇 개에 몰린 소리는 잡음뿐인 주파수 수백 개에 묻힌다. β < 1이면 크기 정보가 남아
  /// 배음 쪽 가중치가 커진다.
  static const _phatBeta         = 0.7;

  static const _minConfidence    = 0.25;   // 블록 유효 신뢰도 하한 (무관한 잡음은 PHAT-β에서 ~0.15까지 나옴)
  static const _minBlocks        = 2;      // 유효 블록이 이보다 적으면 unknown (블록 하나로는 판단하지 않음)
  static const _blockEnergyRatio = 0.3;    // 최대 블록 대비 이 비율 이상인 블록만 사용
  static const _minVoteShare     = 0.6;    // 이긴 방향의 가중치 비율 하한 (미달 시 unknown)
  static const _sideThresholdDeg = 25.0;   // 수평면 기준: 90° ± 이 각도 안이면 앞뒤 구분 불가 (측면 판정은 비활성, 방향 미상 처리)

  /// 자세 게이트 (폰 축 앙각). 30°~95° 기울기에 해당
  static const minAxisElevationDeg = -5.0;
  static const maxAxisElevationDeg = 60.0;

  /// 기기별 채널 매핑 보정. 스테레오 L/R이 어느 마이크인지는 기기마다 다르다.
  /// 폰 상단 끝에서 튼 경적이 음수 lag로 나오면 -1 (설정의 "마이크 채널 반전"이 이 값을 바꾼다).
  static int channelSign = 1;

  /// ch1 = 상단 마이크, ch2 = 하단 마이크 (스테레오 L/R).
  /// [pose]가 없거나 방향을 낼 수 없는 자세면 unknown.
  static SoundDirection analyze(
    List<double> ch1,
    List<double> ch2, {
    DevicePose? pose,
  }) {
    if (pose == null || !pose.canEstimateDirection) return SoundDirection.unknown;
    if (_isDuplicateChannel(ch1, ch2)) return SoundDirection.unknown;

    final blocks = selectBlocks(estimateBlocks(ch1, ch2));
    if (blocks.length < _minBlocks) return SoundDirection.unknown;

    // 거의 지연 0 + 사실상 완벽한 상관 = 같은 신호를 약간 가공해 두 채널에 넣은 가짜 스테레오.
    // (실제 측면 소리도 깨끗하면 0.97 정도까지 나오므로 기준을 그보다 높게 둔다)
    if (blocks.every((b) => b.lag.abs() < 0.25 && b.confidence > 0.99)) {
      return SoundDirection.unknown;
    }

    final votes = <SoundDirection, double>{};
    double total = 0;
    for (final b in blocks) {
      final weight = b.bandEnergy * b.confidence;
      final dir = classifyLag(b.lag, pose);
      votes[dir] = (votes[dir] ?? 0) + weight;
      total += weight;
    }
    if (total <= 0) return SoundDirection.unknown;

    final best = votes.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return best.value / total >= _minVoteShare ? best.key : SoundDirection.unknown;
  }

  /// 지연(샘플) → 수평면 방향. 폰 축 각도 θ를 자세 t로 보정한 방위각 φ로 판단한다:
  /// sin θ = sin t · cos φ  →  cos φ = sin θ / sin t
  static SoundDirection classifyLag(double lag, DevicePose pose) {
    final sinTheta =
        (channelSign * lag / _sampleRate * _speedOfSound / _micDistanceM).clamp(-1.0, 1.0);
    final sinT = sin(pose.tiltFromVerticalDeg * pi / 180);
    if (sinT < 1e-3) return SoundDirection.unknown;
    final cosPhi = (sinTheta / sinT).clamp(-1.0, 1.0);

    // 측면 판정은 일단 사용하지 않는다. 범위가 좁아 반사·흔들림에 정면/후방으로 넘어가기 쉽고,
    // 마이크가 한 축뿐이라 좌우를 구분할 수 없다. 앞뒤를 가르기 어려운 구간은 방향 미상으로 둔다.
    // if (cosPhi.abs() < sin(_sideThresholdDeg * pi / 180)) return SoundDirection.side;
    if (cosPhi.abs() < sin(_sideThresholdDeg * pi / 180)) return SoundDirection.unknown;
    return cosPhi > 0 ? SoundDirection.front : SoundDirection.behind;
  }

  /// 블록마다 대역 제한 GCC-PHAT로 지연을 추정한다 (자세와 무관한 원시 값).
  static List<BlockEstimate> estimateBlocks(List<double> ch1, List<double> ch2) {
    final n = min(ch1.length, ch2.length);
    final blockCount = n ~/ _blockSize;
    final results = <BlockEstimate>[];

    final binHz = _sampleRate / _fftSize;
    final kLow = (_bandLowHz / binHz).ceil();
    final kHigh = min((_bandHighHz / binHz).floor(), _fftSize ~/ 2 - 1);
    final window = _hann;

    final re1 = Float64List(_fftSize), im1 = Float64List(_fftSize);
    final re2 = Float64List(_fftSize), im2 = Float64List(_fftSize);
    final gRe = Float64List(_fftSize), gIm = Float64List(_fftSize);

    for (int b = 0; b < blockCount; b++) {
      final offset = b * _blockSize;
      re1.fillRange(0, _fftSize, 0);
      im1.fillRange(0, _fftSize, 0);
      re2.fillRange(0, _fftSize, 0);
      im2.fillRange(0, _fftSize, 0);
      for (int i = 0; i < _blockSize; i++) {
        re1[i] = ch1[offset + i] * window[i];
        re2[i] = ch2[offset + i] * window[i];
      }
      _fft(re1, im1);
      _fft(re2, im2);

      // 교차 스펙트럼 G = X2 · conj(X1), PHAT-β 정규화 + 대역 마스크.
      // x2[n] = x1[n - d] 이면 G ∝ e^{-i2πkd/N} → 역변환 피크가 +d 에 생긴다.
      gRe.fillRange(0, _fftSize, 0);
      gIm.fillRange(0, _fftSize, 0);
      double bandEnergy = 0;
      double weightSum = 0; // 순수 지연일 때의 피크 높이 / 2 (신뢰도 정규화용)
      for (int k = kLow; k <= kHigh; k++) {
        bandEnergy += re1[k] * re1[k] + im1[k] * im1[k] + re2[k] * re2[k] + im2[k] * im2[k];
        final cr = re2[k] * re1[k] + im2[k] * im1[k];
        final ci = im2[k] * re1[k] - re2[k] * im1[k];
        final mag = sqrt(cr * cr + ci * ci);
        if (mag < 1e-12) continue;
        final scale = pow(mag, -_phatBeta).toDouble();
        gRe[k] = cr * scale;
        gIm[k] = ci * scale;
        gRe[_fftSize - k] = gRe[k];
        gIm[_fftSize - k] = -gIm[k];
        weightSum += mag * scale;
      }
      if (weightSum <= 0 || bandEnergy < 1e-10) continue;

      // 역 DFT = conj(FFT(conj(G))). 실수부만 쓰므로 허수부 부호 처리만 해 준다.
      for (int k = 0; k < _fftSize; k++) {
        gIm[k] = -gIm[k];
      }
      _fft(gRe, gIm);
      final r = gRe; // 정규화 전 상관값, 순수 지연이면 피크 = 2 · weightSum

      int bestLag = 0;
      double best = double.negativeInfinity;
      for (int lag = -_maxLag; lag <= _maxLag; lag++) {
        final v = r[(lag + _fftSize) % _fftSize];
        if (v > best) {
          best = v;
          bestLag = lag;
        }
      }

      // 포물선 보간으로 서브샘플 지연 추정 (탐색 경계에서는 생략)
      double lag = bestLag.toDouble();
      if (bestLag > -_maxLag && bestLag < _maxLag) {
        final y0 = r[(bestLag - 1 + _fftSize) % _fftSize];
        final y2 = r[(bestLag + 1 + _fftSize) % _fftSize];
        final denom = y0 - 2 * best + y2;
        if (denom.abs() > 1e-12) {
          lag += (0.5 * (y0 - y2) / denom).clamp(-0.5, 0.5);
        }
      }

      final confidence = (best / (2 * weightSum)).clamp(0.0, 1.0);
      results.add(BlockEstimate(lag, confidence, bandEnergy));
    }
    return results;
  }

  /// 목표 대역 에너지가 충분하고(경적이 실제로 울린 구간) 신뢰도가 하한 이상인 블록만 남긴다.
  static List<BlockEstimate> selectBlocks(List<BlockEstimate> blocks) {
    if (blocks.isEmpty) return const [];
    final maxEnergy = blocks.map((b) => b.bandEnergy).reduce(max);
    return [
      for (final b in blocks)
        if (b.bandEnergy >= maxEnergy * _blockEnergyRatio && b.confidence >= _minConfidence) b,
    ];
  }

  /// 선택된 블록들의 가중 중앙값 지연 (디버그·채널 확인 표시용). 블록이 없으면 null.
  static double? medianLag(List<BlockEstimate> blocks) {
    if (blocks.isEmpty) return null;
    final sorted = [...blocks]..sort((a, b) => a.lag.compareTo(b.lag));
    final total = sorted.fold<double>(0, (s, b) => s + b.bandEnergy * b.confidence);
    double acc = 0;
    for (final b in sorted) {
      acc += b.bandEnergy * b.confidence;
      if (acc >= total / 2) return b.lag;
    }
    return sorted.last.lag;
  }

  /// 모노 녹음을 두 채널에 복사한 경우 (모노 fallback·가짜 스테레오)
  static bool _isDuplicateChannel(List<double> ch1, List<double> ch2) {
    final n = min(ch1.length, ch2.length);
    for (int i = 0; i < n; i++) {
      if (ch1[i] != ch2[i]) return false;
    }
    return true;
  }

  // ── FFT (radix-2, in-place) ──

  static final Float64List _hann = Float64List.fromList(
    List.generate(_blockSize, (i) => 0.5 - 0.5 * cos(2 * pi * i / (_blockSize - 1))),
  );

  static final Float64List _cosTable = Float64List.fromList(
    List.generate(_fftSize ~/ 2, (i) => cos(2 * pi * i / _fftSize)),
  );
  static final Float64List _sinTable = Float64List.fromList(
    List.generate(_fftSize ~/ 2, (i) => sin(2 * pi * i / _fftSize)),
  );

  /// 순방향 FFT (X_k = Σ x_n e^{-i2πkn/N}), 길이는 _fftSize 고정
  static void _fft(Float64List re, Float64List im) {
    const n = _fftSize;
    for (int i = 1, j = 0; i < n; i++) {
      int bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        final tr = re[i]; re[i] = re[j]; re[j] = tr;
        final ti = im[i]; im[i] = im[j]; im[j] = ti;
      }
    }
    for (int len = 2; len <= n; len <<= 1) {
      final half = len >> 1;
      final step = n ~/ len;
      for (int i = 0; i < n; i += len) {
        for (int k = 0; k < half; k++) {
          final wr = _cosTable[k * step];
          final wi = -_sinTable[k * step];
          final a = i + k, b = a + half;
          final xr = re[b] * wr - im[b] * wi;
          final xi = re[b] * wi + im[b] * wr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
        }
      }
    }
  }
}
