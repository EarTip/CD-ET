import 'dart:async';
import 'dart:typed_data';
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
  static const int _hopSize = _sampleRate ~/ 2;

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

    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _sampleRate,
      numChannels: 1,
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
    double hornScore = _hornClasses.map((i) => scores[i]).reduce((a, b) => a + b) / _hornClasses.length;
    double sirenScore = _sirenClasses.map((i) => scores[i]).reduce((a, b) => a + b) / _sirenClasses.length;
    double brakeScore = _brakeClasses.map((i) => scores[i]).reduce((a, b) => a + b);

    print('🎯 horn=$hornScore siren=$sirenScore brake=$brakeScore');

    const threshold = 0.08;

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