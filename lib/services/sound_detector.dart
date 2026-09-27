import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:flutter_litert/flutter_litert.dart';
import 'tdoa_analyzer.dart';

export 'tdoa_analyzer.dart' show DetectedSound, SoundDirection, SoundDirectionInfo, DetectionEvent;

const _hornClasses  = [302, 303, 312]; // Vehicle horn, Toot, Air horn
const _sirenClasses = [316, 317, 318, 319, 390, 391]; // Emergency vehicle, Police/Ambulance/Fire siren, Siren, Civil defense
const _brakeClasses = [306, 307, 311]; // Skidding, Tire squeal, Air brake

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
  bool _isInferring = false;
  bool _isStereo    = false;
  bool _shouldRun   = false;
  double _threshold = 0.15;
  StreamSubscription<Uint8List>? _streamSub;

  // probe 중에만 설정되는 콜백 — 추론 결과를 외부로 전달
  void Function(List<double> scores)? _onScores;

  Stream<DetectionEvent> get detectionStream => _controller.stream;
  Stream<double> get audioLevelStream => _levelController.stream;

  void setThreshold(double threshold) => _threshold = threshold;

  Future<void> init() async {
    final modelData = await rootBundle.load('assets/models/yamnet.tflite');
    _interpreter = Interpreter.fromBuffer(modelData.buffer.asUint8List());
    debugPrint('✅ 모델 로드 완료');
  }

  Future<void> start() async {
    if (_interpreter == null) await init();
    _shouldRun = true;
    await _startStream();
  }

  Future<void> _startStream() async {
    if (!_shouldRun) return;
    _streamSub?.cancel();
    _streamSub = null;

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
    _streamSub = stream.listen(
      _onAudioData,
      onDone: () {
        // TTS 등 오디오 포커스 변화로 스트림이 닫혔을 때 자동 재연결
        if (_shouldRun) {
          debugPrint('🔄 오디오 스트림 재연결 중...');
          Future.delayed(const Duration(milliseconds: 300), _startStream);
        }
      },
    );
  }

  Future<void> stop() async {
    _shouldRun = false;
    _streamSub?.cancel();
    _streamSub = null;
    await _recorder.stop();
    _bufL.clear();
    _bufR.clear();
    if (!_levelController.isClosed) _levelController.add(0.0);
  }

  void _onAudioData(Uint8List bytes) {
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
      if (_isInferring) {
        _bufL.removeRange(0, _hopSize);
        _bufR.removeRange(0, _hopSize);
        continue;
      }
      final winL = List<double>.unmodifiable(_bufL.sublist(0, _windowSize));
      final winR = List<double>.unmodifiable(_bufR.sublist(0, _windowSize));
      _bufL.removeRange(0, _hopSize);
      _bufR.removeRange(0, _hopSize);
      runInference(winL, winR);
    }
  }

  void runInference(List<double> winL, List<double> winR) {
    if (_interpreter == null) {
      debugPrint('❌ interpreter null — init() 호출 필요');
      return;
    }
    _isInferring = true;
    try {
      final mono = Float32List.fromList(
        List.generate(_windowSize, (i) => (winL[i] + winR[i]) * 0.5),
      );
      final output = [List.filled(521, 0.0)];
      _interpreter!.run([mono], output);

      final scores = output[0];

      _onScores?.call(scores); // probe 중에만 호출됨

      final indexed = List.generate(521, (i) => MapEntry(i, scores[i]))
        ..sort((a, b) => b.value.compareTo(a.value));
      debugPrint('🔊 Top3: ${indexed.take(3).map((e) => '${e.key}=${e.value.toStringAsFixed(3)}').join(', ')}');

      final hornScore  = _hornClasses.map((i) => scores[i]).reduce(max);
      final sirenScore = _sirenClasses.map((i) => scores[i]).reduce(max);
      final brakeScore = _brakeClasses.map((i) => scores[i]).reduce(max);
      debugPrint('🎯 horn=${hornScore.toStringAsFixed(3)} siren=${sirenScore.toStringAsFixed(3)} brake=${brakeScore.toStringAsFixed(3)} threshold=$_threshold');

      final detected = classify(scores);
      if (detected == DetectedSound.none) return;

      final direction = TdoaAnalyzer.analyze(winL, winR);
      _controller.add(DetectionEvent(detected, direction));
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

    final wasRunning = _shouldRun;
    bool detected    = false;

    if (!wasRunning) {
      _shouldRun = true;
      await _startStream();
    }

    _onScores = (scores) {
      final maxAmbient = _trafficAmbientClasses.map((i) => scores[i]).reduce(max);
      debugPrint('🎙️ ambient max=${maxAmbient.toStringAsFixed(3)} threshold=$_ambientThreshold');
      if (maxAmbient > _ambientThreshold) detected = true;
    };

    await Future.delayed(const Duration(seconds: 3));
    _onScores = null;

    if (!wasRunning) await stop();

    return detected;
  }

  void dispose() {
    _onScores = null;
    _recorder.dispose();
    _interpreter?.close();
    _controller.close();
    _levelController.close();
  }
}
