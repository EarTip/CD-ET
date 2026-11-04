import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

enum IndoorOutdoorState { checking, indoor, outdoor }

class IndoorOutdoorService {
  static const _gpsTimeout              = Duration(seconds: 8);
  static const _gpsCheckAccuracyLimit   = 20.0; // 실외 확정 기준 (위성 신호)
  static const _gpsMonitorAccuracyLimit = 40.0; // 실내 전환 기준 (느슨하게)
  static const _indoorDebounce          = Duration(seconds: 8); // 터널/협곡 순간 손실 방지
  static const _cooldownDuration        = Duration(minutes: 2);
  static const _monitorDistanceFilter   = 0;    // debounce 취소를 위해 즉시 정확도 회복 감지 필요
  // 정지 중 outdoor 유지 시 GPS 정확도만으로는 실내 복귀를 못 잡는 경우(창가 등) 대비
  // 소리로 주기적 재확인
  static const _revalidateInterval      = Duration(minutes: 2);

  /// SoundDetector.probeTrafficAmbient 주입
  final Future<bool> Function() _ambientProbe;

  final _controller = StreamController<IndoorOutdoorState>.broadcast();
  StreamSubscription<Position>? _monitorSub;

  IndoorOutdoorState _state    = IndoorOutdoorState.indoor;
  bool  _inCooldown            = false;
  bool  _stationary            = false;
  int   _generation            = 0; // race condition 방지용 세대 카운터
  Timer? _cooldownTimer;
  Timer? _indoorDebounceTimer; // GPS 순간 손실(터널 등) 오판 방지
  Timer? _revalidateTimer;

  IndoorOutdoorService({required Future<bool> Function() ambientProbe})
      : _ambientProbe = ambientProbe;

  Stream<IndoorOutdoorState> get stateStream => _controller.stream;
  IndoorOutdoorState get state => _state;
  bool get isOutdoor => _state == IndoorOutdoorState.outdoor;

  /// 걷기 상태로 전환될 때 1회 호출 — indoor에서만 실제 판단 시작
  Future<void> check() async {
    if (_state == IndoorOutdoorState.checking ||
        _state == IndoorOutdoorState.outdoor) {
      return;
    }

    final gen = ++_generation;
    _emit(IndoorOutdoorState.checking);

    // 1단계: GPS forceLocationManager (캐시 우회, 타임아웃 = 실내 신호)
    // 저비용이라 쿨다운 중에도 항상 실행 — 실제 실외 이동을 최대 2분까지 놓치는 것 방지
    final gpsOutdoor = await _checkGps();
    if (gen != _generation) return; // reportIndoor 등으로 무효화됨

    if (gpsOutdoor == true) {
      _emit(IndoorOutdoorState.outdoor);
      _startOutdoorMonitoring();
      return;
    }

    // 쿨다운 중엔 오디오 probe(마이크 3초, 배터리 비용 큼)만 건너뛰고 indoor 유지
    if (_inCooldown) {
      _emit(IndoorOutdoorState.indoor);
      return;
    }

    // 2단계: YAMNet ambient probe (3초)
    debugPrint('🎙️ YAMNet probe 시작 (GPS 불확실/타임아웃)');
    bool soundOutdoor;
    try {
      soundOutdoor = await _ambientProbe();
    } catch (_) {
      if (gen != _generation) return;
      debugPrint('🎙️ YAMNet probe 실패 → 실내, 쿨다운 ${_cooldownDuration.inMinutes}분');
      _emit(IndoorOutdoorState.indoor);
      _startCooldown();
      return;
    }
    if (gen != _generation) return; // stale 결과 무시

    if (soundOutdoor) {
      debugPrint('🎙️ YAMNet probe: 교통음 감지 → 실외');
      _emit(IndoorOutdoorState.outdoor);
      _startOutdoorMonitoring();
    } else {
      debugPrint('🎙️ YAMNet probe: 교통음 없음 → 실내, 쿨다운 ${_cooldownDuration.inMinutes}분');
      _emit(IndoorOutdoorState.indoor);
      _startCooldown();
    }
  }

  /// 실외 상태에서 GPS 정확도 저하 시 실내 전환 감지
  /// 터널/협곡 등 순간 손실은 _indoorDebounce 후에만 전환 (오판 방지)
  void _startOutdoorMonitoring() {
    _monitorSub?.cancel();
    _monitorSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: _monitorDistanceFilter,
      ),
    ).listen((pos) {
      if (_state != IndoorOutdoorState.outdoor) {
        _cancelIndoorDebounce();
        _stopOutdoorMonitoring();
        return;
      }
      if (pos.accuracy >= _gpsMonitorAccuracyLimit) {
        // 첫 번째 불량 위치: debounce 타이머 시작 (이미 진행 중이면 무시)
        _indoorDebounceTimer ??= Timer(_indoorDebounce, () {
          _indoorDebounceTimer = null;
          if (_state != IndoorOutdoorState.outdoor) return;
          debugPrint('📍 실외→실내 전환 확정 (${_indoorDebounce.inSeconds}s debounce 통과): accuracy=${pos.accuracy.toStringAsFixed(1)}m');
          _generation++;
          _stopOutdoorMonitoring();
          _emit(IndoorOutdoorState.indoor);
        });
      } else {
        // 위성 신호 회복 → debounce 취소 (터널 통과 등)
        if (_indoorDebounceTimer != null) {
          debugPrint('📍 GPS 신호 회복 → 실내 전환 취소 (accuracy=${pos.accuracy.toStringAsFixed(1)}m)');
          _cancelIndoorDebounce();
        }
      }
    });
  }

  void _cancelIndoorDebounce() {
    _indoorDebounceTimer?.cancel();
    _indoorDebounceTimer = null;
  }

  void _stopOutdoorMonitoring() {
    _cancelIndoorDebounce();
    _monitorSub?.cancel();
    _monitorSub = null;
    _stopRevalidation();
  }

  /// SoundManager가 걷기↔정지 전환마다 호출
  /// 정지 중에는 GPS 정확도가 안 변할 수 있어(창가 등) 소리로 주기적 재확인
  void setStationary(bool stationary) {
    _stationary = stationary;
    if (stationary) {
      if (_state != IndoorOutdoorState.outdoor) return;
      _revalidateTimer?.cancel();
      _revalidateTimer = Timer.periodic(_revalidateInterval, (_) => _revalidate());
    } else {
      _stopRevalidation();
    }
  }

  void _stopRevalidation() {
    _revalidateTimer?.cancel();
    _revalidateTimer = null;
  }

  Future<void> _revalidate() async {
    if (!_stationary || _state != IndoorOutdoorState.outdoor) {
      _stopRevalidation();
      return;
    }

    final gen = ++_generation;
    debugPrint('🎙️ 정지 중 실외 재확인 probe 시작');
    bool stillOutdoor;
    try {
      stillOutdoor = await _ambientProbe();
    } catch (_) {
      if (gen != _generation) return;
      if (!_stationary || _state != IndoorOutdoorState.outdoor) return;
      debugPrint('🎙️ 재확인 probe 실패 → 실내로 전환');
      _stopOutdoorMonitoring();
      _emit(IndoorOutdoorState.indoor);
      _startCooldown();
      return;
    }
    if (gen != _generation) return; // stale (그 사이 재이동 등으로 무효화됨)
    if (!_stationary || _state != IndoorOutdoorState.outdoor) return;

    if (stillOutdoor) {
      debugPrint('🎙️ 재확인: 교통음 감지 → 실외 유지');
    } else {
      debugPrint('🎙️ 재확인: 교통음 없음 → 실내로 전환');
      _stopOutdoorMonitoring();
      _emit(IndoorOutdoorState.indoor);
      _startCooldown();
    }
  }

  Future<bool?> _checkGps() async {
    try {
      final LocationSettings settings = Platform.isAndroid
          ? AndroidSettings(
              forceLocationManager: true, // Fused Location 캐시 우회
              accuracy: LocationAccuracy.high,
              timeLimit: _gpsTimeout,
            )
          : AppleSettings(
              accuracy: LocationAccuracy.best,
              timeLimit: _gpsTimeout,
            );

      final pos = await Geolocator.getCurrentPosition(locationSettings: settings);
      final good = pos.accuracy < _gpsCheckAccuracyLimit;
      debugPrint('📍 GPS forced: accuracy=${pos.accuracy.toStringAsFixed(1)}m → ${good ? "실외" : "실내"}');
      return good;
    } catch (_) {
      debugPrint('📍 GPS forced: 타임아웃 → 실내 추정');
      return null;
    }
  }

  void _startCooldown() {
    _inCooldown = true;
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer(_cooldownDuration, () {
      _inCooldown = false;
      debugPrint('⏱️ 쿨다운 종료 → 다음 걷기 시작 시 재판단');
    });
  }

  void _emit(IndoorOutdoorState next) {
    if (next == _state) return;
    _state = next;
    debugPrint('🏠 IndoorOutdoorState → $next');
    if (!_controller.isClosed) _controller.add(next);
  }

  /// stopMonitoring 시 호출 — 구독자에게 indoor 알림
  void reset() {
    _generation++;
    _cooldownTimer?.cancel();
    _inCooldown = false;
    _stationary = false;
    _stopOutdoorMonitoring();
    _emit(IndoorOutdoorState.indoor); // stream 구독자에게도 알림
  }

  void dispose() {
    _generation++;
    _cooldownTimer?.cancel();
    _stopOutdoorMonitoring();
    _controller.close();
  }
}
