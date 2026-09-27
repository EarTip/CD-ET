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

// 실내/외 판단용 ambient 교통음 클래스 (실외 배경 소음)
// 실제 모델에서 검증 필요 — 실외 오디오 샘플로 top-class 확인 권장
const _trafficAmbientClasses = [300, 301, 304, 305, 308]; // Vehicle, Car, Engine, Motor vehicle, Truck
const _ambientThreshold      = 0.08; // 배경음이라 전경음보다 낮은 임계값

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
  bool _isRunning   = false;
  int  _startCount  = 0; // 참조 카운트 — 여러 호출자가 동시에 필요로 할 수 있음
  Future<void>? _startingFuture; // 시작 작업 직렬화 (동시 start() 호출 시 같은 작업 공유)
  double _threshold = 0.15;

  // probe 중에만 설정되는 콜백 — 추론 결과를 외부로 전달
  void Function(List<double> scores)? _onScores;

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

  /// 참조 카운트 기반 시작 — 여러 호출자(mic/probe)가 동시에 필요로 해도 안전.
  /// 이미 시작 작업이 진행 중이면 그 작업을 공유해서 중복 startStream() 방지.
  Future<void> start() async {
    _startCount++;
    if (_startingFuture != null) {
      await _startingFuture;
      return;
    }
    if (_isRunning) return;

    final future = _beginStream();
    _startingFuture = future;
    try {
      await future;
    } catch (e) {
      // 시작 실패 시 이 시작 시도에 걸린 참조는 무효 — 다음 재시도를 허용
      _startCount = 0;
      rethrow;
    } finally {
      _startingFuture = null;
    }
  }

  /// 참조 카운트가 0이 될 때만 실제로 정지 — 다른 호출자가 아직 필요로 하면 유지
  Future<void> stop() async {
    if (_startCount == 0) return;
    _startCount--;
    if (_startCount > 0) return;

    _isRunning = false;
    await _recorder.stop();
    _bufL.clear();
    _bufR.clear();
    if (!_levelController.isClosed) _levelController.add(0.0);
  }

  Future<void> _beginStream() async {
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
    _isRunning = true;
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

      _onScores?.call(scores); // probe 중에만 호출됨

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

  /// IndoorOutdoorService에서 주입받아 실내/외 판단에 사용
  /// 3초간 마이크를 켜서 교통 ambient 클래스가 감지되면 true 반환
  Future<bool> probeTrafficAmbient() async {
    if (_interpreter == null) await init();

    bool detected = false;

    // 참조 카운트로 시작 — 이미 다른 곳(mic)에서 켜둔 상태면 카운트만 증가하고 유지,
    // 대기 중 외부에서 start()가 걸려도 stop()에서 카운트가 남아있으면 실제로는 안 꺼짐
    await start();

    _onScores = (scores) {
      final maxAmbient = _trafficAmbientClasses.map((i) => scores[i]).reduce(max);
      debugPrint('🎙️ ambient max=${maxAmbient.toStringAsFixed(3)} threshold=$_ambientThreshold');
      if (maxAmbient > _ambientThreshold) detected = true;
    };

    await Future.delayed(const Duration(seconds: 3));
    _onScores = null;

    await stop();

    return detected;
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
