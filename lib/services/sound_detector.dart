import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import '../models/sound_classifier.dart';
import '../models/sound_thresholds.dart';
import 'pose_tracker.dart';
import 'tdoa_analyzer.dart';

export 'tdoa_analyzer.dart' show DetectedSound, SoundDirection, SoundDirectionInfo, DetectionEvent;
export '../models/sound_classifier.dart' show SoundClass, SoundClassInfo, ClassificationResult;

/// horn/siren/brake 가 클래스별 연속 횟수([kClassRequiredConsecutive])만큼 임계값 이상으로 감지됐을 때 호출
typedef DangerCallback = void Function(DetectionEvent event, ClassificationResult result);

// ──────────────────────────────────────────────
// 오탐 억제 튜닝 상수
// ──────────────────────────────────────────────

/// 클래스별 기본 임계값 (일반 구역 기준).
/// 단일 라벨은 [kThresholdsAsset] 값을 우선 쓰고, 파일을 못 읽었을 때와 다중 라벨에서만 이 값을 쓴다.
const Map<SoundClass, double> kClassThresholds = {
  SoundClass.horn:    0.5,
  SoundClass.siren:   0.5,
  SoundClass.brake:   0.5,
  SoundClass.bicycle: 0.7,
};

/// 단일 라벨 헤드(model.tflite)의 검증 결과로 뽑은 클래스별 임계값.
/// 모델을 교체하면 노트북의 임계값 계산 셀로 이 파일도 같이 다시 만든다.
const kThresholdsAsset = 'assets/models/thresholds.json';

/// 같은 클래스가 이 횟수만큼 연속 윈도우에서 임계값을 넘어야 이벤트 발생 (맵에 없는 클래스의 기본값)
const int kDefaultRequiredConsecutive = 2;

/// 클래스별 연속 확인 횟수. bicycle 은 오탐이 잦아 한 번 더 확인한다
/// (임계값만 올리면 오탐이 안 줄어든다 — ESC-50 기준 2회로 줄이면 자전거 벨 오탐이 약 2배)
const Map<SoundClass, int> kClassRequiredConsecutive = {
  SoundClass.horn:    2,
  SoundClass.siren:   2,
  SoundClass.brake:   2,
  SoundClass.bicycle: 3,
};

int requiredConsecutiveFor(SoundClass c) =>
    kClassRequiredConsecutive[c] ?? kDefaultRequiredConsecutive;

/// 위치 민감도 임계값([setThreshold])의 기준값. 이 값과의 차이만큼
/// 모든 클래스 임계값을 함께 내리거나 올린다 (예: 횡단보도 0.3 → 전 클래스 -0.2)
const double kBaseSensitivityThreshold = 0.5;

/// 알림(TTS·햅틱) 재생 후 감지를 건너뛰는 시간. audioInterruption=none 이라 녹음이 계속되므로
/// 자기 알림 소리를 다시 감지하지 않도록 막는다 (TTS ≈ 2초 + 창 길이 0.975초)
const Duration kAlertSuppress = Duration(seconds: 3);

/// 윈도우 RMS 가 이 값 미만이면 추론을 건너뛰고 연속 확인을 초기화한다 (≈ -38 dBFS).
/// rms 0.008~0.010 의 약한 상시 소음이 siren 0.9 이상으로 오탐돼 올렸다 (실제 사이렌은 0.016~0.026)
const double kMinRms = 0.012;

/// 실내/외 probe 전용 YAMNet (521개 클래스 점수 출력). 감지는 [SoundClassifier]가 담당한다.
const _ambientModelAsset = 'assets/models/yamnet.tflite';

// 실내/외 판단용 ambient 교통음 클래스 (실외 배경 소음)
// 실제 모델에서 검증 필요 — 실외 오디오 샘플로 top-class 확인 권장
const _trafficAmbientClasses = [300, 301, 304, 305, 308]; // Vehicle, Car, Engine, Motor vehicle, Truck
const _ambientThreshold      = 0.08; // 배경음이라 전경음보다 낮은 임계값

class SoundDetector {
  final AudioRecorder _recorder = AudioRecorder();
  final _controller      = StreamController<DetectionEvent>.broadcast();
  final _levelController = StreamController<double>.broadcast();

  static const int _sampleRate = SoundClassifier.sampleRate;
  static const int _windowSize = SoundClassifier.windowSize;
  static const int _hopSize    = _sampleRate ~/ 4;

  /// Android 녹음 소스 시도 순서. unprocessed(기기 내부 처리 없음)가 방향 추정에는 유리하지만
  /// AGC가 없어 입력 분포가 바뀌고, 분류 임계값과 실내/외 probe 임계값은 mic 기준으로 맞춰져 있다.
  /// 실측으로 영향을 확인하기 전까지는 mic만 쓴다.
  static const _androidSources = [AndroidAudioSource.mic];

  /// 방향 테스트용: 마지막 감지(경적·사이렌 등)의 방향 판단 근거. 개발자 옵션에 표시된다.
  static final lastDirectionDebug = ValueNotifier<String?>(null);

  /// iOS 내장 마이크는 기본이 모노라 2채널로 열어도 같은 신호가 복제된다. 녹음 전에 스테레오로 맞춘다.
  static const _stereoMic = MethodChannel('stereo_mic_channel');

  /// iOS 네이티브 캡처(16kHz 스테레오 PCM16 인터리브)가 흘러오는 채널. record 플러그인은 iOS에서
  /// L/R을 같은 신호로 뭉개기 때문에, iOS는 AVAudioEngine으로 직접 녹음해서 받는다.
  static const _stereoMicEvents = EventChannel('stereo_mic_events');
  StreamSubscription<dynamic>? _nativeSub;
  bool _nativeCapture = false;

  /// iOS 스테레오 설정 결과 (디버그 표시용). Android나 설정 전에는 null.
  static String? _iosStereoInfo;

  final PoseTracker _pose = PoseTracker();

  final List<double> _bufL = [];
  final List<double> _bufR = [];

  final SoundClassifier _classifier;
  bool _isInferring = false;
  bool _disposed    = false;
  Future<void>? _activeInference;
  bool _isStereo    = false;
  bool _isRunning   = false;
  int  _startCount  = 0; // 참조 카운트 — 여러 호출자가 동시에 필요로 할 수 있음
  Future<void>? _startingFuture; // 시작 작업 직렬화 (동시 start() 호출 시 같은 작업 공유)
  double _threshold = kBaseSensitivityThreshold;

  /// 단일 라벨 헤드의 클래스별 기본 임계값 ([kThresholdsAsset] 에서 읽음)
  Map<SoundClass, double> _singleThresholds = kClassThresholds;
  bool _thresholdsLoaded = false;

  // probe 가 처음 호출될 때 로드 — 평소 감지에는 쓰지 않는다
  Interpreter? _ambientInterpreter;
  IsolateInterpreter? _ambientIsolate;

  /// 클래스별 연속 임계값 초과 윈도우 수
  final Map<SoundClass, int> _streaks = {};

  /// 이 시각 전까지는 감지 추론을 건너뛴다 ([suppressFor])
  DateTime? _suppressUntil;
  bool _suppressLogged = false;

  DangerCallback? onDangerDetected;

  SoundDetector({bool multiLabel = false})
      : _classifier = SoundClassifier(multiLabel: multiLabel);

  // probe 중에만 설정되는 콜백 — 추론 결과를 외부로 전달
  void Function(List<double> scores)? _onScores;

  Stream<DetectionEvent> get detectionStream => _controller.stream;
  Stream<double> get audioLevelStream => _levelController.stream;
  bool get multiLabel => _classifier.multiLabel;

  /// 위치 민감도 임계값. 클래스별 임계값에 오프셋으로 반영된다.
  void setThreshold(double threshold) => _threshold = threshold;

  /// 현재 민감도가 반영된 클래스별 실제 임계값
  double thresholdFor(SoundClass c) {
    final base = _classifier.multiLabel ? kClassThresholds : _singleThresholds;
    return ((base[c] ?? kBaseSensitivityThreshold) +
            (_threshold - kBaseSensitivityThreshold))
        .clamp(0.0, 1.0);
  }
  Future<void> setMultiLabel(bool enabled) => _classifier.setMultiLabel(enabled);

  /// [duration] 동안 감지 추론을 건너뛰고 연속 카운트를 비운다. probe 점수 전달은 계속된다.
  void suppressFor(Duration duration) {
    final until = DateTime.now().add(duration);
    if (_suppressUntil == null || until.isAfter(_suppressUntil!)) _suppressUntil = until;
    _suppressLogged = false;
    _streaks.clear();
  }

  Future<void> init() async {
    await _loadThresholds();
    await _classifier.load();
  }

  Future<void> _loadThresholds() async {
    if (_thresholdsLoaded) return;
    _thresholdsLoaded = true;
    try {
      final source = await rootBundle.loadString(kThresholdsAsset);
      _singleThresholds = parseSingleLabelThresholds(source, kClassThresholds);
      debugPrint('✅ 임계값 로드: ${_singleThresholds.entries.map((e) => '${e.key.name}=${e.value}').join(' ')}');
    } catch (e) {
      debugPrint('⚠️ $kThresholdsAsset 로드 실패, 기본 임계값 사용: $e');
    }
  }

  /// 참조 카운트 기반 시작 — 여러 호출자(mic/probe)가 동시에 필요로 해도 안전.
  /// 이미 시작 작업이 진행 중이면 그 작업을 공유해서 중복 startStream() 방지.
  Future<void> start() async {
    _startCount++;

    // 공유한 시작 작업이 끝나도 스트림이 실제로 떠 있다는 보장은 없다.
    // (_beginStream()이 참조 없음을 확인하고 _stopStream()을 기다리는 사이 들어온 start()는
    // 그 정리 작업을 공유하게 되어 스트림 없이 반환될 수 있음)
    // 그래서 완료 후 참조가 남아 있는데 실행 중이 아니면 다시 시작한다.
    // 종료된 객체는 다시 시작하지 않는다 (_beginStream이 조기 반환해도 이 루프가 계속 재시도하지 않게).
    while (_startCount > 0 && !_isRunning && !_disposed) {
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
    if (_nativeCapture) {
      _nativeCapture = false;
      // 취소를 기다리는 동안 새 start()가 끝나 새 구독이 _nativeSub에 들어올 수 있으므로,
      // 먼저 현재 구독만 분리해서 참조를 비운 뒤 취소한다.
      final sub = _nativeSub;
      _nativeSub = null;
      await sub?.cancel();
      try {
        await _stereoMic.invokeMethod('stopCapture');
      } catch (e) {
        debugPrint('⚠️ 네이티브 캡처 정지 실패: $e');
      }
    } else {
      await _recorder.stop();
    }
    _streaks.clear();
    _bufL.clear();
    _bufR.clear();
    if (!_levelController.isClosed) _levelController.add(0.0);
  }

  Future<void> _beginStream() async {
    if (!_classifier.isLoaded) await init();

    // 프로필은 시작할 때마다 고른다. iOS 네이티브 캡처가 성공하면 아래에서 iOS용으로 바꾼다.
    TdoaAnalyzer.useDefaultProfile();
    if (Platform.isIOS) {
      await _enableIosStereo();
      if (_disposed) return;
    }

    // iOS: 네이티브 캡처가 되면 그걸 쓰고, 안 되면 아래 record 경로(가짜 스테레오)로 내려간다.
    if (Platform.isIOS && await _startIosNativeCapture()) {
      _isStereo = true;
      _isRunning = true;
      _pose.start();
      if (_startCount == 0) await _stopStream();
      return;
    }
    if (_disposed) return;

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
    if (Platform.isIOS) unawaited(_logIosStereoStatus());
    if (_isStereo) _pose.start();

    // 시작 작업 도중 참조가 전부 사라졌다면(대기 중 stop() 호출) 바로 정리
    if (_startCount == 0) {
      await _stopStream();
    }
  }

  /// record 대신 AVAudioEngine으로 직접 녹음한다. 성공하면 true.
  /// 극성 패턴이 Stereo로 안 잡혔으면 두 채널이 복제본일 수 있어 false로 돌려 record 경로로 내려보낸다.
  Future<bool> _startIosNativeCapture() async {
    try {
      final info = await _stereoMic.invokeMapMethod<String, dynamic>('startCapture');
      if (_disposed) {
        // 시작하는 사이 dispose됐다. 엔진만 끄고 구독은 만들지 않는다.
        await _stereoMic.invokeMethod('stopCapture');
        return false;
      }
      final pattern = info?['polarPattern'];
      debugPrint('🎙️ 네이티브 캡처 시작: ${info?['engineChannels']}ch · ${info?['dataSource']} · $pattern');
      if (pattern != 'Stereo') {
        debugPrint('⚠️ 스테레오 극성 패턴이 아니라서 네이티브 캡처를 쓰지 않음');
        await _stereoMic.invokeMethod('stopCapture');
        return false;
      }
      _nativeSub = _stereoMicEvents.receiveBroadcastStream().listen(
        (data) => _onAudioData(data as Uint8List),
        onError: (Object e) {
          debugPrint('❌ 네이티브 캡처 오류: $e');
          unawaited(_recoverFromNativeError());
        },
      );
      _nativeCapture = true;
      TdoaAnalyzer.useIosStereoProfile();
      debugPrint('✅ 마이크 스트림 시작 (stereo=true, native AVAudioEngine)');
      return true;
    } catch (e) {
      debugPrint('⚠️ 네이티브 캡처 실패, record로 대체: $e');
      return false;
    }
  }

  /// 네이티브 캡처가 도중에 끊겼을 때(예: 이어폰 마이크로 입력이 1채널이 되어 엔진 재시작 실패) 복구한다.
  /// 구독과 엔진을 정리해 실행 상태를 내리고, 아직 쓰는 쪽(참조)이 남아 있으면 다시 시작한다.
  /// 다시 시작하면 네이티브를 먼저 시도하고, 안 되면 record 경로로 내려가며
  /// TDOA 프로필·스테레오 여부도 그 안에서 새 입력 경로에 맞게 다시 정해진다.
  Future<void> _recoverFromNativeError() async {
    // 오류가 연달아 와도 처음 한 번만 처리한다 (_stopStream이 await 전에 _nativeCapture를 내린다).
    if (!_nativeCapture || _disposed) return;
    await _stopStream();
    if (_startCount == 0 || _disposed || _startingFuture != null) return;

    final future = _beginStream();
    _startingFuture = future;
    try {
      await future;
    } catch (e) {
      _startCount = 0;
      debugPrint('❌ 캡처 복구 실패: $e');
    } finally {
      _startingFuture = null;
    }
  }

  Future<void> _enableIosStereo() async {
    try {
      final info = await _stereoMic.invokeMapMethod<String, dynamic>('enable');
      if (info == null) return;
      _iosStereoInfo = info['stereo'] == true
          ? 'iOS 스테레오 ${info['channels']}ch · ${info['dataSource']} · ${info['polarPattern']} · ${info['orientation']}'
          : 'iOS 스테레오 실패: ${info['reason'] ?? '입력 ${info['channels']}ch'}';
      debugPrint('🎙️ $_iosStereoInfo');
    } catch (e) {
      _iosStereoInfo = 'iOS 스테레오 설정 오류: $e';
      debugPrint('⚠️ $_iosStereoInfo');
    }
  }

  /// record 플러그인이 세션을 다시 설정한 뒤에도 스테레오 극성 패턴이 유지되는지 확인한다.
  Future<void> _logIosStereoStatus() async {
    try {
      final info = await _stereoMic.invokeMapMethod<String, dynamic>('status');
      debugPrint('🎙️ 녹음 시작 후 입력: ${info?['channels']}ch · ${info?['dataSource']} · ${info?['polarPattern']}');
    } catch (e) {
      debugPrint('⚠️ iOS 입력 상태 조회 실패: $e');
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
      // 자세는 창이 확정되는 이 시점에 고정한다. 추론이 끝난 뒤에 읽으면 그 사이 바뀐 자세가 섞인다.
      final pose = _isStereo ? _pose.current : null;
      _activeInference = _runInference(winL, winR, pose);
      unawaited(_activeInference);
    }
  }

  Future<void> _runInference(List<double> winL, List<double> winR, DevicePose? pose) async {
    // dispatch 시점의 probe 콜백 — 이후에 시작된 probe로 이전 구간의 결과가 새지 않게 한다.
    final onScores = _onScores;
    try {
      // record 경로의 iOS는 R이 L의 위상이 틀어진 복제본이라 평균을 내면 서로 상쇄되어 입력이 크게
      // 줄고 감지 점수가 떨어진다. 그 경우만 L을 쓰고, 네이티브 캡처(진짜 스테레오)는 평균을 쓴다.
      final mono = Float32List.fromList(
        List.generate(_windowSize, (i) => Platform.isIOS && !_nativeCapture ? winL[i] : (winL[i] + winR[i]) * 0.5),
      );

      // probe 중일 때만 521개 점수 YAMNet 을 돌린다 (무음 스킵보다 먼저 — 배경음 판단용)
      final ambient = _ambientIsolate;
      if (onScores != null && ambient != null) {
        final output = [List.filled(521, 0.0)];
        await ambient.run([mono], output);
        // dispatch 시점의 probe가 아직 활성일 때만 전달
        if (identical(onScores, _onScores)) onScores(output[0]);
      }

      final suppressUntil = _suppressUntil;
      if (suppressUntil != null) {
        if (DateTime.now().isBefore(suppressUntil)) {
          _streaks.clear();
          if (!_suppressLogged) {
            _suppressLogged = true;
            debugPrint('🔇 알림 재생 중 감지 건너뜀 (${kAlertSuppress.inMilliseconds}ms)');
          }
          return;
        }
        _suppressUntil = null;
      }

      double sumSq = 0;
      for (final x in mono) {
        sumSq += x * x;
      }
      final rms = sqrt(sumSq / mono.length);
      if (rms < kMinRms) {
        _streaks.clear();
        if (kDebugMode) {
          debugPrint('🔇 무음 스킵 rms=${rms.toStringAsFixed(4)} (< $kMinRms)');
        }
        return;
      }

      final result = await _classifier.classify(mono);
      if (_disposed) return;
      // 추론 도중 알림이 울렸으면 이 창의 결과는 버린다
      final until = _suppressUntil;
      if (until != null && DateTime.now().isBefore(until)) return;

      final hits = result.detected(thresholdFor);
      for (final c in SoundClass.values) {
        if (c == SoundClass.background) continue;
        _streaks[c] = hits.contains(c) ? (_streaks[c] ?? 0) + 1 : 0;
      }
      final confirmed =
          hits.where((c) => _streaks[c]! >= requiredConsecutiveFor(c)).toList();

      if (kDebugMode) {
        // 클래스=현재/필요 (예: bicycle=2/3)
        final streakLog = SoundClass.values
            .where((c) => c != SoundClass.background)
            .map((c) => '${c.name}=${_streaks[c]}/${requiredConsecutiveFor(c)}')
            .join(' ');
        debugPrint('🎯 rms=${rms.toStringAsFixed(4)} $result top=${result.top.name} '
            'sens=$_threshold multiLabel=${result.multiLabel} '
            '| streak $streakLog'
            '${confirmed.isEmpty ? '' : ' → ✅ ${confirmed.map((c) => c.name).join(',')}'}');
      }

      if (confirmed.isEmpty) return;

      // 모노 녹음은 두 채널이 같아 방향 정보가 없다
      final direction = _isStereo
          ? TdoaAnalyzer.analyze(winL, winR, pose: pose)
          : SoundDirection.unknown;
      for (final c in confirmed) {
        final event = DetectionEvent(c.detectedSound, direction);
        _reportDirectionDebug(event.sound, direction, winL, winR, pose);
        if (c.isDanger) onDangerDetected?.call(event, result);
        if (!_controller.isClosed) _controller.add(event);
      }
    } catch (e, st) {
      debugPrint('❌ 분류 추론 오류: $e\n$st');
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
    } else if (TdoaAnalyzer.isDuplicateChannel(winL, winR)) {
      detail = '두 채널이 동일 (가짜 스테레오) — 방향 추정 불가'
          '${_iosStereoInfo == null ? '' : '\n$_iosStereoInfo'}';
    } else {
      final blocks = TdoaAnalyzer.selectBlocks(TdoaAnalyzer.estimateBlocks(winL, winR));
      final lag = TdoaAnalyzer.medianLag(blocks);
      final lagText = lag == null ? '-' : '${lag >= 0 ? '+' : ''}${lag.toStringAsFixed(1)}';
      final poseText = pose == null
          ? '자세 정보 없음'
          : '앙각 ${pose.axisElevationDeg.toStringAsFixed(0)}° · 화면 ${pose.screenUp ? '위' : '아래'}'
              '${pose.canEstimateDirection ? '' : ' (방향 낼 수 없는 자세)'}';
      final lags = blocks.map((b) => b.lag).toList()..sort();
      final range = lags.isEmpty
          ? ''
          : ' (블록 ${lags.first.toStringAsFixed(1)}~${lags.last.toStringAsFixed(1)})';
      detail = 'lag $lagText$range · 유효 블록 ${blocks.length}개 · $poseText'
          '${_iosStereoInfo == null ? '' : '\n$_iosStereoInfo'}';
    }
    lastDirectionDebug.value = '${sound.name} → ${direction.label}\n$detail';
    debugPrint('🧭 ${sound.name} → ${direction.name} | $detail');
  }

  Future<void> _loadAmbientModel() async {
    if (_ambientIsolate != null) return;
    final modelData = await rootBundle.load(_ambientModelAsset);
    final interpreter = Interpreter.fromBuffer(modelData.buffer.asUint8List());
    _ambientInterpreter = interpreter;
    _ambientIsolate = await IsolateInterpreter.create(address: interpreter.address);
    debugPrint('✅ 실내/외 probe 모델 로드 완료');
  }

  /// IndoorOutdoorService에서 주입받아 실내/외 판단에 사용
  /// 3초간 마이크를 켜서 교통 ambient 클래스가 감지되면 true 반환
  Future<bool> probeTrafficAmbient() async {
    await _loadAmbientModel();

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
    // 진행 중인 시작이 있으면 끝날 때까지 기다린 뒤 정리한다. 안 그러면 그 시작이 dispose 이후에
    // 엔진·구독·자세 추적을 만들어 남긴다 (_beginStream이 각 비동기 경계 뒤에서 _disposed를 확인한다).
    final starting = _startingFuture;
    if (starting != null) {
      try {
        await starting;
      } catch (_) {}
    }
    // probe가 start() 참조를 쥐고 있으면 _stopStream()이 호출되지 않으므로 직접 해제한다
    _pose.stop();
    if (_nativeCapture) {
      _nativeCapture = false;
      await _nativeSub?.cancel();
      _nativeSub = null;
      try {
        await _stereoMic.invokeMethod('stopCapture');
      } catch (_) {}
    }
    await _recorder.dispose();
    // isolate가 참조하는 네이티브 인터프리터를 닫기 전에 진행 중인 추론을 기다린다.
    try {
      await _activeInference;
    } catch (_) {}
    await _classifier.close();
    await _ambientIsolate?.close();
    _ambientInterpreter?.close();
    await _controller.close();
    await _levelController.close();
  }
}
