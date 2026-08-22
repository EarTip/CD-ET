import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'tdoa_analyzer.dart' show RawAudioChunk;

/// [VoiceActivityDetector]가 검출한 발화 구간 전체(가변 길이, 캡처 시점의
/// 채널 구성 그대로). VAD 판단 자체는 모노로 합쳐서 하지만, 캡처는 스테레오
/// 채널을 그대로 들고 있어서 호출부가 `TdoaAnalyzer`로 방향 추정을 그대로
/// 할 수 있다(예전 고정 윈도우 방식과 동일하게).
class CapturedUtterance {
  final Float32List left;
  final Float32List right;
  const CapturedUtterance(this.left, this.right);

  /// (L+R)*0.5 다운믹스 — 임베더에 넘길 모노 신호가 필요할 때.
  Float32List toMono() => Float32List.fromList(
        List.generate(left.length, (i) => (left[i] + right[i]) * 0.5),
      );
}

enum _VadPhase { silence, speech }

/// 에너지 기반 스트리밍 발화 구간 검출기. `SoundDetector.rawAudioStream`처럼
/// 계속 흘러들어오는 오디오에서 "지금 말하고 있는 구간"의 시작/끝을 찾아서,
/// 그 구간만 잘라 [utteranceStream]으로 내보낸다.
///
/// `base_compare_hubert_zipformer_wav2vec2.ipynb`에서 오프라인으로 검증한
/// 조건(무음 트리밍 후 발화 전체를 인코더에 통째로 forward)과 최대한 같은
/// 입력을 온디바이스에서도 만들어주는 게 목적이다. 예전 `NameCallDetector`의
/// 고정 슬라이딩 윈도우(1초/50% overlap)는 노트북에서 검증한 적 없는,
/// 발화 타이밍과 무관하게 잘린 조각을 인코더에 넣는 방식이라 — 특히
/// self-attention 계열(HuBERT/wav2vec2)이 발화 전체 문맥을 봐야 잘 나온
/// 성능이 그대로 옮겨진다는 보장이 없었다.
///
/// 알고리즘: [_frameMs]ms 프레임마다 RMS 에너지를 dB로 재서, 무음 구간
/// 동안 천천히 적응하는 노이즈 플로어보다 [onsetMarginDb] 이상 크면 발화
/// 시작으로, 이후 [offsetMarginDb] 아래로 [hangoverMs] 이상 지속되면 발화
/// 종료로 판정한다(onset/offset 마진을 다르게 둬서 경계에서의 flicker를
/// 막는 히스테리시스). 초성이 안 잘리도록 시작 직전 [preRollMs]만큼은 항상
/// 붙이고, 헛트리거 방지로 [minSpeechMs]보다 짧게 캡처된 건 버리며, 발화가
/// 비정상적으로 길게 이어지면 [maxUtteranceMs]에서 강제로 끊는다(노트북의
/// `CLIP_SECONDS_TRIM=4.0s`에 대응).
///
/// [start]에 `earlyEmitSamples`를 넘기면(현재 `NameCallDetector`가 임베더의
/// `clipSamplesForEnrollment`를 전달) 무음 종료를 기다리지 않고, 캡처된
/// 샘플 수가 그 길이에 도달하는 즉시 방출한다. `NameEmbedder._fitToFixedLength`가
/// 앞부분 그 길이만큼만 쓰고 나머지는 버리기 때문에, 발화가 그보다 길게
/// 이어지는 동안 계속 듣는 건 임베딩 결과에 아무 영향 없이 지연시간만
/// 늘릴 뿐이다 — 이름은 거의 항상 발화 맨 앞에서 불리므로, 목표 길이가
/// 차는 순간이 곧 "이름 부분은 이미 다 들었다"는 뜻이 된다. 발화 자체가
/// 그 길이보다 짧게 끝나면 이 조기 방출보다 오프셋(hangover) 판정이 먼저
/// 온다.
///
/// 조기 방출/[maxUtteranceMs] 강제 컷오프는 화자가 아직 말하는 도중에
/// 끊는 것이라, 방출 직후 다음 프레임도 여전히 크면 곧바로 재트리거된다
/// (preRoll을 채울 틈도 없이). 그러면 발화 하나가 [cooldownMs] 간격으로
/// 계속 쪼개져 나오게 되므로, 그 두 경우에 한해 방출 후 [cooldownMs] 동안
/// 재트리거를 억제한다(hangover로 자연 종료된 경우는 이미 진짜 무음이
/// 뒤따르므로 쿨다운이 필요 없다).
class VoiceActivityDetector {
  VoiceActivityDetector({
    double onsetMarginDb = _defaultOnsetMarginDb,
    double offsetMarginDb = _defaultOffsetMarginDb,
    int hangoverMs = _defaultHangoverMs,
    int minSpeechMs = _defaultMinSpeechMs,
    int maxUtteranceMs = _defaultMaxUtteranceMs,
    int preRollMs = _defaultPreRollMs,
    int cooldownMs = _defaultCooldownMs,
  })  : _onsetMarginDb = onsetMarginDb,
        _offsetMarginDb = offsetMarginDb,
        _hangoverFrames = (hangoverMs / _frameMs).round(),
        _minSpeechMs = minSpeechMs,
        _maxUtteranceFrames = (maxUtteranceMs / _frameMs).round(),
        _preRollFrames = (preRollMs / _frameMs).round(),
        _cooldownFrames = (cooldownMs / _frameMs).round();

  static const int _sampleRate = 16000;
  static const int _frameMs = 20;
  static const int _frameSize = _sampleRate * _frameMs ~/ 1000; // 320 samples

  /// 조기 방출 샘플 수를 넘기는 쪽(`NameCallDetector`)이 자기 모델의
  /// 샘플레이트가 이 VAD와 같은지 확인할 수 있도록 공개해둔다 — 다르면
  /// 리샘플링 없이 그대로 비교할 수 없으므로 조기 방출을 비활성화해야 한다.
  static const int sampleRate = _sampleRate;

  static const double _defaultOnsetMarginDb = 12.0;
  static const double _defaultOffsetMarginDb = 6.0;
  static const int _defaultHangoverMs = 300;
  static const int _defaultMinSpeechMs = 300;
  static const int _defaultMaxUtteranceMs = 4000;
  static const int _defaultPreRollMs = 140;
  static const int _defaultCooldownMs = 200;

  // 노이즈 플로어는 무음 프레임에서만 완만하게(alpha 작게) 적응시킨다 —
  // 발화 프레임의 큰 에너지가 플로어를 끌어올리면 안 되므로.
  static const double _noiseFloorAlpha = 0.05;
  static const double _noiseFloorFloorDb = -70.0;
  static const double _noiseFloorCeilDb = -10.0;
  static const double _initialNoiseFloorDb = -50.0;

  final double _onsetMarginDb;
  final double _offsetMarginDb;
  final int _hangoverFrames;
  final int _minSpeechMs;
  final int _maxUtteranceFrames;
  final int _preRollFrames;
  final int _cooldownFrames;

  final List<double> _pendingL = [];
  final List<double> _pendingR = [];
  final List<double> _preRollL = [];
  final List<double> _preRollR = [];
  List<double> _captureL = [];
  List<double> _captureR = [];

  _VadPhase _phase = _VadPhase.silence;
  double _noiseFloorDb = _initialNoiseFloorDb;
  int _silenceRunFrames = 0;

  /// null이면 조기 방출 비활성화(항상 오프셋/최대길이까지 기다림). [start]
  /// 호출마다 갱신된다 — 자세한 내용은 클래스 doc 참고.
  int? _earlyEmitSamples;

  /// 0보다 크면 그만큼(프레임 수) 재트리거를 억제하는 중 — 조기 방출/강제
  /// 컷오프 직후에만 켜진다. 클래스 doc의 쿨다운 설명 참고.
  int _cooldownRemainingFrames = 0;

  StreamSubscription<RawAudioChunk>? _subscription;
  final _utteranceController =
      StreamController<CapturedUtterance>.broadcast();
  final _speakingController = StreamController<bool>.broadcast();

  /// 발화 구간이 끝날 때마다(무음 확정 또는 최대 길이 도달) 하나씩 나온다.
  Stream<CapturedUtterance> get utteranceStream =>
      _utteranceController.stream;

  /// UI 피드백용(선택) — 지금 발화 중으로 판단했는지.
  Stream<bool> get isSpeakingStream => _speakingController.stream;

  /// [earlyEmitSamples]를 넘기면 무음 종료를 기다리지 않고 캡처된 샘플이
  /// 그 길이에 도달하는 즉시 발화를 방출한다 — 클래스 doc 참고.
  void start(Stream<RawAudioChunk> rawAudioStream, {int? earlyEmitSamples}) {
    _subscription?.cancel();
    _earlyEmitSamples = earlyEmitSamples;
    _resetState();
    _subscription = rawAudioStream.listen(_onChunk);
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _resetState();
  }

  void _resetState() {
    _pendingL.clear();
    _pendingR.clear();
    _preRollL.clear();
    _preRollR.clear();
    _captureL = [];
    _captureR = [];
    _phase = _VadPhase.silence;
    _noiseFloorDb = _initialNoiseFloorDb;
    _silenceRunFrames = 0;
    _cooldownRemainingFrames = 0;
  }

  void _onChunk(RawAudioChunk chunk) {
    _pendingL.addAll(chunk.left);
    _pendingR.addAll(chunk.right);
    while (_pendingL.length >= _frameSize) {
      final frameL = _pendingL.sublist(0, _frameSize);
      final frameR = _pendingR.sublist(0, _frameSize);
      _pendingL.removeRange(0, _frameSize);
      _pendingR.removeRange(0, _frameSize);
      _processFrame(frameL, frameR);
    }
  }

  void _processFrame(List<double> l, List<double> r) {
    if (_cooldownRemainingFrames > 0) {
      // 쿨다운 중엔 이 프레임을 통째로 무시한다(노이즈 플로어 적응/preRoll
      // 축적/onset 판정 전부 스킵) — 화자가 계속 말하고 있어도 최소 이
      // 간격만큼은 새 발화로 잡히지 않는다.
      _cooldownRemainingFrames--;
      return;
    }

    final db = _frameDb(l, r);

    if (_phase == _VadPhase.silence) {
      if (db > _noiseFloorDb + _onsetMarginDb) {
        // preRoll(직전까지의 무음 프레임들)을 먼저 캡처 버퍼로 옮기고,
        // 지금 프레임(트리거가 된 바로 그 프레임)을 이어붙인다 — preRoll엔
        // 아직 이 프레임이 안 들어가 있으므로 중복 추가가 아니다.
        _startSpeech();
        _captureL.addAll(l);
        _captureR.addAll(r);
      } else {
        _pushPreRoll(l, r);
        _noiseFloorDb = (_noiseFloorDb * (1 - _noiseFloorAlpha) +
                db * _noiseFloorAlpha)
            .clamp(_noiseFloorFloorDb, _noiseFloorCeilDb);
      }
      return;
    }

    // _phase == speech
    _captureL.addAll(l);
    _captureR.addAll(r);
    if (db > _noiseFloorDb + _offsetMarginDb) {
      _silenceRunFrames = 0;
    } else {
      _silenceRunFrames++;
    }

    final earlyEmitSamples = _earlyEmitSamples;
    // 지금 이어지고 있는 무음 구간(_silenceRunFrames)은 아직 hangover가
    // 확정한 "발화 내용"이 아니다 — 이걸 빼고 봐야, 짧은 발화 뒤에 무음이
    // 붙는 것만으로 목표 길이가 찬 것처럼 잘못 조기 방출되는 걸 막는다.
    final contentSamples = _captureL.length - _silenceRunFrames * _frameSize;
    final reachedHangover = _silenceRunFrames >= _hangoverFrames;
    final reachedEarlyTarget =
        earlyEmitSamples != null && contentSamples >= earlyEmitSamples;

    if (reachedHangover || reachedEarlyTarget) {
      if (reachedEarlyTarget && !reachedHangover) {
        // 이름은 거의 항상 발화 맨 앞에서 불리고, 임베더는 어차피 앞부분
        // earlyEmitSamples만큼만 쓰고 나머지는 버린다 — 그러니 그 길이가
        // 찬 시점에서 발화가 계속돼도(무음 판정을 더 기다려도) 임베딩
        // 결과는 달라지지 않는다. 지연시간만 줄이기 위해 바로 방출한다.
        debugPrint(
            '⚡ VAD: 목표 길이(${earlyEmitSamples * 1000 ~/ _sampleRate}ms) 도달 '
            '— 조기 방출');
      }
      // 진행 중인 무음 구간(있다면)은 트리밍한다 — hangover 확정이든 조기
      // 방출이든, 방금 겪은 무음까지 발화 내용으로 넣을 이유는 없다.
      _completeUtterance(
        trimTrailingSilence: true,
        // hangover로 끝난 거면 이미 진짜 무음이 뒤따르고 있어 자연스러운
        // 간격이 생긴다. 조기 방출은 화자가 여전히 말하는 도중일 수 있어
        // 쿨다운으로 최소 간격을 강제한다.
        startCooldown: !reachedHangover,
      );
    } else if (_captureL.length >= _maxUtteranceFrames * _frameSize) {
      debugPrint('⏱️ VAD: 최대 길이(${_maxUtteranceFrames * _frameMs}ms) 도달 '
          '— 강제 컷오프');
      _completeUtterance(trimTrailingSilence: false, startCooldown: true);
    }
  }

  double _frameDb(List<double> l, List<double> r) {
    double sumSq = 0;
    for (int i = 0; i < l.length; i++) {
      final mono = (l[i] + r[i]) * 0.5;
      sumSq += mono * mono;
    }
    final rms = math.sqrt(sumSq / l.length);
    return 20 * math.log(rms + 1e-9) / math.ln10;
  }

  void _pushPreRoll(List<double> l, List<double> r) {
    _preRollL.addAll(l);
    _preRollR.addAll(r);
    final maxLen = _preRollFrames * _frameSize;
    if (_preRollL.length > maxLen) {
      _preRollL.removeRange(0, _preRollL.length - maxLen);
      _preRollR.removeRange(0, _preRollR.length - maxLen);
    }
  }

  void _startSpeech() {
    _phase = _VadPhase.speech;
    _silenceRunFrames = 0;
    _captureL = [..._preRollL];
    _captureR = [..._preRollR];
    if (!_speakingController.isClosed) _speakingController.add(true);
  }

  /// 발화 캡처를 마무리해서 방출(또는 blip이면 폐기)한다. "끝났다"는 뜻의
  /// finish가 아니라 completeUtterance인 이유: 이걸 부르는 시점이 항상
  /// "발화가 실제로 끝남"(자연 종료)은 아니기 때문 — 목표 길이 도달로
  /// 조기 방출되거나 [_maxUtteranceFrames]로 강제 컷오프될 때는 화자가
  /// 여전히 말하는 중일 수 있다. 세 경우 모두 "지금까지 캡처한 걸 확정해서
  /// 내보낸다"는 동작은 같아서 한 메서드로 묶여 있다.
  ///
  /// [startCooldown]이 true면 방출 직후 [_cooldownFrames]만큼 재트리거를
  /// 억제한다 — 화자가 말하는 도중에 끊는 조기 방출/강제 컷오프에서만 쓴다.
  void _completeUtterance({
    required bool trimTrailingSilence,
    bool startCooldown = false,
  }) {
    var l = _captureL;
    var r = _captureR;
    if (trimTrailingSilence) {
      // hangover로 확정하는 데 쓴 무음 프레임들은 발화 내용이 아니므로
      // 잘라낸다 — 노트북의 top_db 트리밍이 오프라인에서 하던 일과 같다.
      final trim = math.min(_silenceRunFrames * _frameSize, l.length);
      l = l.sublist(0, l.length - trim);
      r = r.sublist(0, r.length - trim);
    }

    _phase = _VadPhase.silence;
    _silenceRunFrames = 0;
    _captureL = [];
    _captureR = [];
    _preRollL.clear();
    _preRollR.clear();
    _cooldownRemainingFrames = startCooldown ? _cooldownFrames : 0;
    if (!_speakingController.isClosed) _speakingController.add(false);

    final durationMs = l.length * 1000 ~/ _sampleRate;
    if (durationMs < _minSpeechMs) {
      debugPrint('🔈 VAD: ${durationMs}ms 발화 폐기(너무 짧음, blip으로 판단)');
      return;
    }

    debugPrint('🗣️ VAD: 발화 캡처 ${durationMs}ms');
    if (!_utteranceController.isClosed) {
      _utteranceController.add(CapturedUtterance(
        Float32List.fromList(l),
        Float32List.fromList(r),
      ));
    }
  }

  void dispose() {
    _subscription?.cancel();
    _utteranceController.close();
    _speakingController.close();
  }
}
