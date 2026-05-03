import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

enum DetectedSound { horn, siren, brake, none }

const _hornClasses = [27, 302, 382, 390, 394];
const _sirenClasses = [316, 317, 318, 396, 397, 398, 399, 400];
const _brakeClasses = [308];

class SoundDetector {
  final AudioRecorder _recorder = AudioRecorder();
  final _detectionController = StreamController<DetectedSound>.broadcast();

  static const int _sampleRate = 16000;
  static const int _windowSize = 15600;
  static const int _hopSize = _sampleRate ~/ 4;

  final List<double> _buffer = [];
  Interpreter? _interpreter;
  bool _isInferring = false;

  Stream<DetectedSound> get detectionStream => _detectionController.stream;

  Future<void> init() async {
    final modelData = await rootBundle.load('assets/models/yamnet.tflite');
    _interpreter = Interpreter.fromBuffer(modelData.buffer.asUint8List());
    print('✅ 모델 로드 완료');
  }

  Future<void> start() async {
    if (_interpreter == null) await init();

    final stream = await _recorder.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _sampleRate,
      numChannels: 1,
      iosConfig: IosRecordConfig(
        categoryOptions: [
          IosAudioCategoryOption.mixWithOthers,
          IosAudioCategoryOption.duckOthers,
          IosAudioCategoryOption.allowBluetoothA2DP,
        ],
      ),
      androidConfig: AndroidRecordConfig(
        audioSource: AndroidAudioSource.mic, // 내장 마이크 강제
        muteAudio: false,                    // 음악 음소거 안 함
        manageBluetooth: false,              // SCO 차단 → A2DP 고음질 유지
        audioManagerMode: AudioManagerMode.modeNormal, // 통화 모드 전환 안 함
      ),
    ));
    print('✅ 마이크 스트림 시작');
    stream.listen(_onAudioData);
  }

  Future<void> stop() async {
    await _recorder.stop();
    _buffer.clear();
  }

  void _onAudioData(Uint8List bytes) {
    print('📥 오디오: ${bytes.length}bytes / 버퍼: ${_buffer.length}/$_windowSize');
    for (int i = 0; i < bytes.length - 1; i += 2) {
      int sample = bytes[i] | (bytes[i + 1] << 8);
      if (sample > 32767) sample -= 65536;
      _buffer.add(sample / 32768.0);
    }

    while (_buffer.length >= _windowSize) {
      if (_isInferring) {
        // 추론 중엔 버퍼 누적만 하고 hopSize만큼만 제거
        // (버퍼를 통째로 버리지 않아 연속 감지 가능)
        _buffer.removeRange(0, _hopSize);
        continue;
      }
      print('🧠 추론 실행');
      final window = Float32List.fromList(_buffer.sublist(0, _windowSize));
      _buffer.removeRange(0, _hopSize);
      _runInference(window);
    }
  }

  void _runInference(Float32List samples) {
    if (_interpreter == null) return;
    _isInferring = true;

    try {
      final input = [samples];
      final output = [List.filled(521, 0.0)];

      _interpreter!.run(input, output);

      final scores = output[0];
      final indexed = List.generate(521, (i) => MapEntry(i, scores[i]));
      indexed.sort((a, b) => b.value.compareTo(a.value));
      print('🔊 Top3: ${indexed.take(3).map((e) => '${e.key}=${e.value.toStringAsFixed(3)}').join(', ')}');

      final detected = _classify(scores);
      if (detected != DetectedSound.none) {
        _detectionController.add(detected);
      }
    } catch (e) {
      print('❌ 추론 오류: $e');
    } finally {
      _isInferring = false;
    }
  }

  DetectedSound _classify(List<double> scores) {
    // 평균 대신 max 사용 → 클래스 수 차이로 인한 불균형 해소
    // siren 8개 클래스 평균 < horn 5개 클래스 평균 문제 해결
    final hornScore = _hornClasses.map((i) => scores[i]).reduce(max);
    final sirenScore = _sirenClasses.map((i) => scores[i]).reduce(max);
    final brakeScore = _brakeClasses.map((i) => scores[i]).reduce(max);

    print('🎯 horn=$hornScore siren=$sirenScore brake=$brakeScore');

    const threshold = 0.15; // max 기반이라 임계값 상향 (오탐 방지)

    if (sirenScore > threshold && sirenScore >= hornScore && sirenScore >= brakeScore) {
      return DetectedSound.siren;
    }
    if (hornScore > threshold && hornScore >= sirenScore && hornScore >= brakeScore) {
      return DetectedSound.horn;
    }
    if (brakeScore > threshold) {
      return DetectedSound.brake;
    }
    return DetectedSound.none;
  }

  void dispose() {
    _recorder.dispose();
    _interpreter?.close();
    _detectionController.close();
  }
}