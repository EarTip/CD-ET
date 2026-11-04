import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import '../models/sound_classifier.dart';
import 'tdoa_analyzer.dart';

export 'tdoa_analyzer.dart' show DetectedSound, SoundDirection, SoundDirectionInfo, DetectionEvent;
export '../models/sound_classifier.dart' show SoundClass, SoundClassInfo, ClassificationResult;

/// horn/siren/brake 가 연속 [kRequiredConsecutive] 윈도우 임계값 이상으로 감지됐을 때 호출
typedef DangerCallback = void Function(DetectionEvent event, ClassificationResult result);

// ──────────────────────────────────────────────
// 오탐 억제 튜닝 상수
// ──────────────────────────────────────────────

/// 클래스별 기본 임계값 (일반 구역 기준)
const Map<SoundClass, double> kClassThresholds = {
  SoundClass.horn:    0.5,
  SoundClass.siren:   0.5,
  SoundClass.brake:   0.5,
  SoundClass.bicycle: 0.7,
};

/// 같은 클래스가 이 횟수만큼 연속 윈도우에서 임계값을 넘어야 이벤트 발생
const int kRequiredConsecutive = 2;

/// 위치 민감도 임계값([setThreshold])의 기준값. 이 값과의 차이만큼
/// 모든 클래스 임계값을 함께 내리거나 올린다 (예: 횡단보도 0.3 → 전 클래스 -0.2)
const double kBaseSensitivityThreshold = 0.5;

class SoundDetector {
  final AudioRecorder _recorder = AudioRecorder();
  final _controller      = StreamController<DetectionEvent>.broadcast();
  final _levelController = StreamController<double>.broadcast();

  static const int _sampleRate = SoundClassifier.sampleRate;
  static const int _windowSize = SoundClassifier.windowSize;
  static const int _hopSize    = _sampleRate ~/ 4;

  /// 윈도우 RMS 가 이 값 미만이면 무음으로 보고 추론을 건너뛴다 (≈ -46 dBFS)
  static const double _silenceRms = 0.005;

  final List<double> _bufL = [];
  final List<double> _bufR = [];

  final SoundClassifier _classifier;
  bool _isInferring = false;
  bool _disposed    = false;
  Future<void>? _activeInference;
  bool _isStereo    = false;
  double _threshold = kBaseSensitivityThreshold;

  /// 클래스별 연속 임계값 초과 윈도우 수
  final Map<SoundClass, int> _streaks = {};

  DangerCallback? onDangerDetected;

  SoundDetector({bool multiLabel = false})
      : _classifier = SoundClassifier(multiLabel: multiLabel);

  Stream<DetectionEvent> get detectionStream => _controller.stream;
  Stream<double> get audioLevelStream => _levelController.stream;
  bool get multiLabel => _classifier.multiLabel;

  /// 위치 민감도 임계값. 클래스별 임계값에 오프셋으로 반영된다.
  void setThreshold(double threshold) => _threshold = threshold;

  /// 현재 민감도가 반영된 클래스별 실제 임계값
  double thresholdFor(SoundClass c) =>
      ((kClassThresholds[c] ?? kBaseSensitivityThreshold) +
              (_threshold - kBaseSensitivityThreshold))
          .clamp(0.0, 1.0);
  Future<void> setMultiLabel(bool enabled) => _classifier.setMultiLabel(enabled);

  Future<void> init() => _classifier.load();

  Future<void> start() async {
    if (!_classifier.isLoaded) await init();

    Stream<Uint8List> stream;
    try {
      stream = await _recorder.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 2,
        iosConfig: const IosRecordConfig(
          categoryOptions: [
            IosAudioCategoryOption.mixWithOthers,
            IosAudioCategoryOption.duckOthers,
            IosAudioCategoryOption.allowBluetoothA2DP,
          ],
        ),
        androidConfig: const AndroidRecordConfig(
          audioSource: AndroidAudioSource.mic,
          muteAudio: false,
          manageBluetooth: false,
          audioManagerMode: AudioManagerMode.modeNormal,
        ),
      ));
      _isStereo = true;
    } catch (_) {
      stream = await _recorder.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
        iosConfig: const IosRecordConfig(
          categoryOptions: [
            IosAudioCategoryOption.mixWithOthers,
            IosAudioCategoryOption.duckOthers,
            IosAudioCategoryOption.allowBluetoothA2DP,
          ],
        ),
        androidConfig: const AndroidRecordConfig(
          audioSource: AndroidAudioSource.mic,
          muteAudio: false,
          manageBluetooth: false,
          audioManagerMode: AudioManagerMode.modeNormal,
        ),
      ));
      _isStereo = false;
    }
    debugPrint('✅ 마이크 스트림 시작 (stereo=$_isStereo)');
    stream.listen(_onAudioData);
  }

  Future<void> stop() async {
    await _recorder.stop();
    _streaks.clear();
    _bufL.clear();
    _bufR.clear();
    if (!_levelController.isClosed) _levelController.add(0.0);
  }

  void _onAudioData(Uint8List bytes) {
    if (_disposed) return;
    if (_isStereo) {
      for (int i = 0; i + 3 < bytes.length; i += 4) {
        int sL = bytes[i]     | (bytes[i + 1] << 8);
        int sR = bytes[i + 2] | (bytes[i + 3] << 8);
        if (sL > 32767) sL -= 65536;
        if (sR > 32767) sR -= 65536;
        _bufL.add(sL / 32768.0);
        _bufR.add(sR / 32768.0);
      }
    } else {
      for (int i = 0; i + 1 < bytes.length; i += 2) {
        int s = bytes[i] | (bytes[i + 1] << 8);
        if (s > 32767) s -= 65536;
        final v = s / 32768.0;
        _bufL.add(v);
        _bufR.add(v);
      }
    }

    if (_bufL.isNotEmpty && !_levelController.isClosed) {
      final recent = _bufL.length > 800 ? _bufL.sublist(_bufL.length - 800) : _bufL;
      final rms = sqrt(recent.map((x) => x * x).reduce((a, b) => a + b) / recent.length);
      _levelController.add(rms.clamp(0.0, 1.0));
    }

    while (_bufL.length >= _windowSize) {
      // 추론이 이미 진행 중이면(비동기·isolate) 백로그를 버리고 최신 창을 우선한다.
      if (_isInferring) {
        _bufL.removeRange(0, _hopSize);
        _bufR.removeRange(0, _hopSize);
        continue;
      }
      final winL = List<double>.of(_bufL.sublist(0, _windowSize));
      final winR = List<double>.of(_bufR.sublist(0, _windowSize));
      _bufL.removeRange(0, _hopSize);
      _bufR.removeRange(0, _hopSize);

      // await 이전에 동기로 플래그를 세워야 가드가 실제로 동작한다.
      _isInferring = true;
      _activeInference = _runInference(winL, winR);
      unawaited(_activeInference);
    }
  }

  Future<void> _runInference(List<double> winL, List<double> winR) async {
    try {
      final mono = Float32List.fromList(
        List.generate(_windowSize, (i) => (winL[i] + winR[i]) * 0.5),
      );

      double sumSq = 0;
      for (final x in mono) {
        sumSq += x * x;
      }
      final rms = sqrt(sumSq / mono.length);
      if (rms < _silenceRms) {
        _streaks.clear();
        if (kDebugMode) {
          debugPrint('🔇 무음 스킵 rms=${rms.toStringAsFixed(4)} (< $_silenceRms)');
        }
        return;
      }

      final result = await _classifier.classify(mono);
      if (_disposed) return;

      final hits = result.detected(thresholdFor);
      for (final c in SoundClass.values) {
        if (c == SoundClass.background) continue;
        _streaks[c] = hits.contains(c) ? (_streaks[c] ?? 0) + 1 : 0;
      }
      final confirmed =
          hits.where((c) => _streaks[c]! >= kRequiredConsecutive).toList();

      if (kDebugMode) {
        final streakLog = SoundClass.values
            .where((c) => c != SoundClass.background)
            .map((c) => '${c.name}=${_streaks[c]}')
            .join(' ');
        debugPrint('🎯 rms=${rms.toStringAsFixed(4)} $result top=${result.top.name} '
            'sens=$_threshold multiLabel=${result.multiLabel} '
            '| streak $streakLog (need $kRequiredConsecutive)'
            '${confirmed.isEmpty ? '' : ' → ✅ ${confirmed.map((c) => c.name).join(',')}'}');
      }

      if (confirmed.isEmpty) return;

      final direction = TdoaAnalyzer.analyze(winL, winR);
      for (final c in confirmed) {
        final event = DetectionEvent(c.detectedSound, direction);
        if (c.isDanger) onDangerDetected?.call(event, result);
        if (!_controller.isClosed) _controller.add(event);
      }
    } catch (e, st) {
      debugPrint('❌ 분류 추론 오류: $e\n$st');
    } finally {
      _isInferring = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _recorder.dispose();
    // isolate가 참조하는 네이티브 인터프리터를 닫기 전에 진행 중인 추론을 기다린다.
    try {
      await _activeInference;
    } catch (_) {}
    await _classifier.close();
    await _controller.close();
    await _levelController.close();
  }
}
