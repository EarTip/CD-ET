import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import '../services/tdoa_analyzer.dart';

// ──────────────────────────────────────────────
// 분류 클래스 (model.tflite / model_multilabel.tflite 출력 순서와 동일해야 함)
// ──────────────────────────────────────────────

enum SoundClass { horn, siren, brake, bicycle, background }

extension SoundClassInfo on SoundClass {
  DetectedSound get detectedSound => switch (this) {
        SoundClass.horn       => DetectedSound.horn,
        SoundClass.siren      => DetectedSound.siren,
        SoundClass.brake      => DetectedSound.brake,
        SoundClass.bicycle    => DetectedSound.bicycle,
        SoundClass.background => DetectedSound.none,
      };

  /// 즉시 경고가 필요한 위험 소리
  bool get isDanger =>
      this == SoundClass.horn || this == SoundClass.siren || this == SoundClass.brake;
}

class ClassificationResult {
  final Map<SoundClass, double> probabilities;
  final bool multiLabel;

  const ClassificationResult(this.probabilities, {required this.multiLabel});

  /// 확률이 가장 높은 클래스
  SoundClass get top =>
      probabilities.entries.reduce((a, b) => b.value > a.value ? b : a).key;

  /// 임계값 이상으로 감지된 클래스 (background 제외, 확률 내림차순)
  /// - 단일 라벨: top-1 이 background 가 아니고 해당 클래스 임계값 이상일 때만 1개
  /// - 다중 라벨: 각 클래스 임계값 이상인 클래스 모두
  List<SoundClass> detected(double Function(SoundClass) thresholdOf) {
    if (!multiLabel) {
      final t = top;
      if (t == SoundClass.background || probabilities[t]! < thresholdOf(t)) return const [];
      return [t];
    }
    final hits = probabilities.entries
        .where((e) => e.key != SoundClass.background && e.value >= thresholdOf(e.key))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return hits.map((e) => e.key).toList();
  }

  @override
  String toString() => probabilities.entries
      .map((e) => '${e.key.name}=${e.value.toStringAsFixed(3)}')
      .join(' ');
}

// ──────────────────────────────────────────────
// YAMNet 임베딩 → 분류 헤드 2단계 분류기
// ──────────────────────────────────────────────

class SoundClassifier {
  static const int sampleRate    = 16000;
  static const int windowSize    = 15600; // 0.975초
  static const int _embeddingDim = 1024;

  static const _yamnetAsset     = 'assets/models/yamnet.tflite';
  static const _singleHeadAsset = 'assets/models/model.tflite';
  static const _multiHeadAsset  = 'assets/models/model_multilabel.tflite';

  static const double defaultMultiLabelThreshold = 0.5;

  bool _multiLabel;

  Interpreter? _yamnet;
  IsolateInterpreter? _yamnetIsolate;
  int _embeddingOutputIndex = 0;

  final Map<bool, Interpreter> _heads = {};
  final Map<bool, IsolateInterpreter> _headIsolates = {};

  SoundClassifier({bool multiLabel = false}) : _multiLabel = multiLabel;

  bool get multiLabel => _multiLabel;
  bool get isLoaded => _yamnetIsolate != null && _headIsolates.containsKey(_multiLabel);

  Future<void> load() async {
    if (_yamnet == null) {
      _yamnet = await _loadInterpreter(_yamnetAsset);
      _prepareYamnet(_yamnet!);
      _yamnetIsolate = await IsolateInterpreter.create(address: _yamnet!.address);
    }
    await _loadHead(_multiLabel);
    debugPrint('✅ 분류 모델 로드 완료 (multiLabel=$_multiLabel)');
  }

  /// 단일/다중 라벨 전환. 필요한 헤드는 처음 사용할 때 로드한다.
  Future<void> setMultiLabel(bool enabled) async {
    if (_yamnet != null) await _loadHead(enabled);
    _multiLabel = enabled;
  }

  /// 16kHz mono [-1, 1] 오디오 15600 샘플 → 클래스별 확률
  Future<ClassificationResult> classify(Float32List waveform) async {
    if (waveform.length != windowSize) {
      throw ArgumentError('waveform 길이는 $windowSize 이어야 합니다 (현재 ${waveform.length})');
    }
    if (!isLoaded) await load();

    final multiLabel = _multiLabel;
    final embedding = await extractEmbedding(waveform);

    final output = [List<double>.filled(SoundClass.values.length, 0.0)];
    await _headIsolates[multiLabel]!.run([embedding], output);

    final probs = output[0];
    return ClassificationResult(
      {for (final c in SoundClass.values) c: probs[c.index]},
      multiLabel: multiLabel,
    );
  }

  /// YAMNet 으로 1024차원 임베딩 추출 (프레임이 여러 개면 평균)
  Future<List<double>> extractEmbedding(Float32List waveform) async {
    final yamnet = _yamnet!;
    final inputShape = yamnet.getInputTensor(0).shape;
    final Object input = inputShape.length == 1 ? waveform : [waveform];

    // 원본 YAMNet(scores/embeddings/spectrogram)과 임베딩 전용 export 모두 지원
    final outputs = <int, Object>{
      for (final (i, t) in yamnet.getOutputTensors().indexed) i: _zeros(t.shape),
    };
    await _yamnetIsolate!.runForMultipleInputs([input], outputs);

    final raw = outputs[_embeddingOutputIndex]!;
    if (raw is List<double>) return raw;

    final frames = (raw as List).cast<List<double>>();
    if (frames.length == 1) return frames[0];
    final mean = List<double>.filled(_embeddingDim, 0.0);
    for (final f in frames) {
      for (int i = 0; i < _embeddingDim; i++) {
        mean[i] += f[i] / frames.length;
      }
    }
    return mean;
  }

  Future<void> close() async {
    await _yamnetIsolate?.close();
    _yamnet?.close();
    _yamnetIsolate = null;
    _yamnet = null;
    for (final isolate in _headIsolates.values) {
      await isolate.close();
    }
    for (final head in _heads.values) {
      head.close();
    }
    _headIsolates.clear();
    _heads.clear();
  }

  // ── 내부 ──────────────────────────────────────

  Future<Interpreter> _loadInterpreter(String asset) async {
    final data = await rootBundle.load(asset);
    return Interpreter.fromBuffer(data.buffer.asUint8List());
  }

  void _prepareYamnet(Interpreter yamnet) {
    final inputShape = yamnet.getInputTensor(0).shape;
    if (inputShape.last != windowSize) {
      yamnet.resizeInputTensor(
          0, inputShape.length == 1 ? [windowSize] : [1, windowSize]);
      yamnet.allocateTensors();
    }

    final outputs = yamnet.getOutputTensors();
    final idx = outputs.indexWhere((t) => t.shape.last == _embeddingDim);
    if (idx < 0) {
      throw StateError(
          'yamnet.tflite 에 $_embeddingDim 차원 임베딩 출력이 없습니다: ${outputs.map((t) => t.shape).toList()}');
    }
    _embeddingOutputIndex = idx;
    debugPrint('🧩 YAMNet input=$inputShape outputs=${outputs.map((t) => t.shape).toList()} → embedding #$idx');
  }

  Future<void> _loadHead(bool multiLabel) async {
    if (_headIsolates.containsKey(multiLabel)) return;
    final head = await _loadInterpreter(multiLabel ? _multiHeadAsset : _singleHeadAsset);

    final outShape = head.getOutputTensor(0).shape;
    if (outShape.last != SoundClass.values.length) {
      head.close();
      throw StateError('분류 헤드 출력 크기 불일치: $outShape (기대: ${SoundClass.values.length})');
    }

    _heads[multiLabel] = head;
    _headIsolates[multiLabel] = await IsolateInterpreter.create(address: head.address);
  }

  static Object _zeros(List<int> shape) => shape.length == 1
      ? List<double>.filled(shape[0], 0.0)
      : List.generate(shape[0], (_) => _zeros(shape.sublist(1)));
}
