import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'tdoa_analyzer.dart';

export 'tdoa_analyzer.dart' show DetectedSound, SoundDirection, SoundDirectionInfo, DetectionEvent;

const _hornClasses  = [27, 302, 382, 390, 394];
const _sirenClasses = [316, 317, 318, 396, 397, 398, 399, 400];
const _brakeClasses = [308];

class SoundDetector {
  final AudioRecorder _recorder = AudioRecorder();
  final _controller      = StreamController<DetectionEvent>.broadcast();
  final _levelController = StreamController<double>.broadcast();

  static const int _sampleRate = 16000;
  static const int _windowSize = 15600;
  static const int _hopSize    = _sampleRate ~/ 4;

  final List<double> _bufL = [];
  final List<double> _bufR = [];

  Interpreter? _interpreter;
  IsolateInterpreter? _isolateInterpreter;
  bool _isInferring = false;
  bool _disposed    = false;
  Future<void>? _activeInference;
  bool _isStereo    = false;
  double _threshold = 0.15;

  Stream<DetectionEvent> get detectionStream => _controller.stream;
  Stream<double> get audioLevelStream => _levelController.stream;

  void setThreshold(double threshold) => _threshold = threshold;

  Future<void> init() async {
    final modelData = await rootBundle.load('assets/models/yamnet.tflite');
    _interpreter = Interpreter.fromBuffer(modelData.buffer.asUint8List());
    _isolateInterpreter =
        await IsolateInterpreter.create(address: _interpreter!.address);
    debugPrint('✅ 모델 로드 완료');
  }

  Future<void> start() async {
    if (_interpreter == null) await init();

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
    final isolate = _isolateInterpreter;
    if (isolate == null) {
      debugPrint('❌ interpreter null — init() 호출 필요');
      _isInferring = false;
      return;
    }
    try {
      final mono = Float32List.fromList(
        List.generate(_windowSize, (i) => (winL[i] + winR[i]) * 0.5),
      );
      final output = [List.filled(521, 0.0)];
      await isolate.run([mono], output);

      final scores = output[0];

      if (kDebugMode) {
        final indexed = List.generate(521, (i) => MapEntry(i, scores[i]))
          ..sort((a, b) => b.value.compareTo(a.value));
        debugPrint('🔊 Top3: ${indexed.take(3).map((e) => '${e.key}=${e.value.toStringAsFixed(3)}').join(', ')}');

        final hornScore  = _hornClasses.map((i) => scores[i]).reduce(max);
        final sirenScore = _sirenClasses.map((i) => scores[i]).reduce(max);
        final brakeScore = _brakeClasses.map((i) => scores[i]).reduce(max);
        debugPrint('🎯 horn=${hornScore.toStringAsFixed(3)} siren=${sirenScore.toStringAsFixed(3)} brake=${brakeScore.toStringAsFixed(3)} threshold=$_threshold');
      }

      final detected = classify(scores);
      if (detected == DetectedSound.none) return;

      final direction = TdoaAnalyzer.analyze(winL, winR);
      if (!_controller.isClosed) _controller.add(DetectionEvent(detected, direction));
    } catch (e, st) {
      debugPrint('❌ YAMNet 추론 오류: $e\n$st');
    } finally {
      _isInferring = false;
    }
  }

  DetectedSound classify(List<double> scores) {
    final hornScore  = _hornClasses.map((i) => scores[i]).reduce(max);
    final sirenScore = _sirenClasses.map((i) => scores[i]).reduce(max);
    final brakeScore = _brakeClasses.map((i) => scores[i]).reduce(max);

    if (sirenScore > _threshold && sirenScore >= hornScore && sirenScore >= brakeScore) return DetectedSound.siren;
    if (hornScore  > _threshold && hornScore  >= sirenScore && hornScore  >= brakeScore) return DetectedSound.horn;
    if (brakeScore > _threshold) return DetectedSound.brake;
    return DetectedSound.none;
  }

  Future<void> dispose() async {
    _disposed = true;
    await _recorder.dispose();
    // isolate가 참조하는 네이티브 인터프리터를 닫기 전에 진행 중인 추론을 기다린다.
    try {
      await _activeInference;
    } catch (_) {}
    await _isolateInterpreter?.close();
    _interpreter?.close();
    await _controller.close();
    await _levelController.close();
  }
}
