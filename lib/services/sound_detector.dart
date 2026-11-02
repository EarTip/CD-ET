import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'pose_tracker.dart';
import 'tdoa_analyzer.dart';

export 'tdoa_analyzer.dart' show DetectedSound, SoundDirection, SoundDirectionInfo, DetectionEvent;

const _hornClasses  = [27, 302, 382, 390, 394];
const _sirenClasses = [316, 317, 318, 396, 397, 398, 399, 400];
const _brakeClasses = [308];
const _bicycleClasses = [198]; // Bicycle bell

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

  /// Android 녹음 소스 시도 순서. unprocessed(기기 내부 처리 없음)가 방향 추정에는 유리하지만
  /// AGC가 없어 YAMNet 점수 분포가 바뀌고, 감지 임계값(0.04~0.08)과 실내/외 probe 임계값은
  /// mic 기준으로 맞춰져 있다. 실측으로 영향을 확인하기 전까지는 mic만 쓴다.
  static const _androidSources = [AndroidAudioSource.mic];

  /// 방향 테스트용: 마지막 감지(경적·사이렌 등)의 방향 판단 근거. 개발자 옵션에 표시된다.
  static final lastDirectionDebug = ValueNotifier<String?>(null);

  final PoseTracker _pose = PoseTracker();

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

    // 공유한 시작 작업이 끝나도 스트림이 실제로 떠 있다는 보장은 없다.
    // (_beginStream()이 참조 없음을 확인하고 _stopStream()을 기다리는 사이 들어온 start()는
    // 그 정리 작업을 공유하게 되어 스트림 없이 반환될 수 있음)
    // 그래서 완료 후 참조가 남아 있는데 실행 중이 아니면 다시 시작한다.
    while (_startCount > 0 && !_isRunning) {
      final pending = _startingFuture;
      if (pending != null) {
        await pending;
        continue;
      }

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
  }

  /// 참조 카운트가 0이 될 때만 실제로 정지 — 다른 호출자가 아직 필요로 하면 유지
  Future<void> stop() async {
    if (_startCount == 0) return;
    _startCount--;
    if (_startCount > 0) return;

    // 아직 시작(_beginStream) 작업이 진행 중이면 여기서 정지하지 않음 —
    // 시작이 끝난 뒤 _beginStream()이 카운트를 다시 확인해서 직접 정리한다.
    if (_startingFuture != null) return;

    await _stopStream();
  }

  Future<void> _stopStream() async {
    _isRunning = false;
    _pose.stop();
    await _recorder.stop();
    _bufL.clear();
    _bufR.clear();
    if (!_levelController.isClosed) _levelController.add(0.0);
  }

  Future<void> _beginStream() async {
    if (_interpreter == null) await init();

    // 스테레오를 소스 순서대로 시도하고, 전부 실패하면 모노(mic)로 연다.
    Stream<Uint8List>? stream;
    AndroidAudioSource source = AndroidAudioSource.mic;
    for (final s in _androidSources) {
      try {
        stream = await _recorder.startStream(_recordConfig(numChannels: 2, source: s));
        source = s;
        _isStereo = true;
        break;
      } catch (e) {
        debugPrint('⚠️ 스테레오 녹음 실패 (source=${s.name}): $e');
      }
    }
    if (stream == null) {
      stream = await _recorder.startStream(_recordConfig(numChannels: 1, source: AndroidAudioSource.mic));
      source = AndroidAudioSource.mic;
      _isStereo = false;
    }
    debugPrint('✅ 마이크 스트림 시작 (stereo=$_isStereo, source=${source.name})');
    stream.listen(_onAudioData);
    _isRunning = true;
    if (_isStereo) _pose.start();

    // 시작 작업 도중 참조가 전부 사라졌다면(대기 중 stop() 호출) 바로 정리
    if (_startCount == 0) {
      await _stopStream();
    }
  }

  RecordConfig _recordConfig({required int numChannels, required AndroidAudioSource source}) {
    return RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _sampleRate,
      numChannels: numChannels,
      audioInterruption: AudioInterruptionMode.none,
      iosConfig: const IosRecordConfig(
        categoryOptions: [
          IosAudioCategoryOption.mixWithOthers,
          IosAudioCategoryOption.duckOthers,
          IosAudioCategoryOption.allowBluetoothA2DP,
        ],
      ),
      androidConfig: AndroidRecordConfig(
        audioSource: source,
        muteAudio: false,
        manageBluetooth: false,
        audioManagerMode: AudioManagerMode.modeNormal,
      ),
    );
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
    // dispatch 시점의 probe 콜백 — 이후에 시작된 probe로 이전 구간의 결과가 새지 않게 한다.
    final onScores = _onScores;
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

      // dispatch 시점의 probe가 아직 활성일 때만 전달
      if (identical(onScores, _onScores)) onScores?.call(scores);

      if (kDebugMode) {
        final indexed = List.generate(521, (i) => MapEntry(i, scores[i]))
          ..sort((a, b) => b.value.compareTo(a.value));
        debugPrint('🔊 Top3: ${indexed.take(3).map((e) => '${e.key}=${e.value.toStringAsFixed(3)}').join(', ')}');

        final hornScore  = _hornClasses.map((i) => scores[i]).reduce(max);
        final sirenScore = _sirenClasses.map((i) => scores[i]).reduce(max);
        final brakeScore = _brakeClasses.map((i) => scores[i]).reduce(max);
        final bicycleScore = _bicycleClasses.map((i) => scores[i]).reduce(max);
        debugPrint('🎯 horn=${hornScore.toStringAsFixed(3)} siren=${sirenScore.toStringAsFixed(3)} brake=${brakeScore.toStringAsFixed(3)} bicycle=${bicycleScore.toStringAsFixed(3)} threshold=$_threshold');
      }

      final detected = classify(scores);
      if (detected == DetectedSound.none) return;

      // 모노 녹음은 두 채널이 같아 방향 정보가 없다
      final pose = _pose.current;
      final direction = _isStereo
          ? TdoaAnalyzer.analyze(winL, winR, pose: pose)
          : SoundDirection.unknown;
      _reportDirectionDebug(detected, direction, winL, winR, pose);
      if (!_controller.isClosed) _controller.add(DetectionEvent(detected, direction));
    } catch (e, st) {
      debugPrint('❌ YAMNet 추론 오류: $e\n$st');
    } finally {
      _isInferring = false;
    }
  }

  /// 방향이 왜 그렇게 나왔는지 보여준다. lag 부호: + = 폰 상단 쪽에서 옴, - = 하단 쪽.
  /// 폰 상단 끝에서 튼 경적은 +5~+7, 하단 끝은 -5~-7 근처가 정상이다.
  /// 부호가 반대면 이 기기는 채널이 반대(개발자 옵션 "마이크 채널 반전"),
  /// 어디서 틀어도 0 근처면 가짜 스테레오라 방향 추정이 불가능하다.
  void _reportDirectionDebug(
    DetectedSound sound,
    SoundDirection direction,
    List<double> winL,
    List<double> winR,
    DevicePose? pose,
  ) {
    final String detail;
    if (!_isStereo) {
      detail = '모노 녹음 — 이 기기는 방향 추정 불가';
    } else {
      final blocks = TdoaAnalyzer.selectBlocks(TdoaAnalyzer.estimateBlocks(winL, winR));
      final lag = TdoaAnalyzer.medianLag(blocks);
      final lagText = lag == null ? '-' : '${lag >= 0 ? '+' : ''}${lag.toStringAsFixed(1)}';
      final poseText = pose == null
          ? '자세 정보 없음'
          : '앙각 ${pose.axisElevationDeg.toStringAsFixed(0)}° · 화면 ${pose.screenUp ? '위' : '아래'}'
              '${pose.canEstimateDirection ? '' : ' (방향 낼 수 없는 자세)'}';
      detail = 'lag $lagText · 유효 블록 ${blocks.length}개 · $poseText';
    }
    lastDirectionDebug.value = '${sound.name} → ${direction.label}\n$detail';
    debugPrint('🧭 ${sound.name} → ${direction.name} | $detail');
  }

  DetectedSound classify(List<double> scores) {
    final hornScore  = _hornClasses.map((i) => scores[i]).reduce(max);
    final sirenScore = _sirenClasses.map((i) => scores[i]).reduce(max);
    final brakeScore = _brakeClasses.map((i) => scores[i]).reduce(max);
    final bicycleScore = _bicycleClasses.map((i) => scores[i]).reduce(max);

    if (sirenScore > _threshold && sirenScore >= hornScore) return DetectedSound.siren;
    if (hornScore  > _threshold && hornScore  >= sirenScore) return DetectedSound.horn;
    if (bicycleScore > _threshold && bicycleScore >= brakeScore) return DetectedSound.bicycle;
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

    void onScores(List<double> scores) {
      final maxAmbient = _trafficAmbientClasses.map((i) => scores[i]).reduce(max);
      debugPrint('🎙️ ambient max=${maxAmbient.toStringAsFixed(3)} threshold=$_ambientThreshold');
      if (maxAmbient > _ambientThreshold) detected = true;
    }
    _onScores = onScores;

    await Future.delayed(const Duration(seconds: 3));
    // 마지막 창의 추론이 진행 중일 수 있으므로, 점수가 콜백에 반영된 뒤에 해제한다.
    // (_runInference는 예외를 모두 잡으므로 던지지 않고, 대기 시간은 추론 한 번으로 제한됨)
    await _activeInference;
    // 다른 probe가 콜백을 등록했다면 그 콜백을 지우지 않는다
    if (identical(_onScores, onScores)) _onScores = null;

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
