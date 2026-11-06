import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

enum SensitivityLevel { normal, elevated, high }

extension SensitivityThreshold on SensitivityLevel {
  double get threshold => switch (this) {
        // 분류 헤드(softmax/sigmoid) 확률 기준
        SensitivityLevel.high     => 0.3, // 횡단보도 80m 이내
        SensitivityLevel.elevated => 0.4, // 주요 도로 30m 이내
        SensitivityLevel.normal   => 0.5, // 일반 구역
      };

  String get label => switch (this) {
        SensitivityLevel.high     => '고감도 (횡단보도)',
        SensitivityLevel.elevated => '강화 (차도 근처)',
        SensitivityLevel.normal   => '일반',
      };
}

class GeofenceService {
  static const _crosswalkRadius = 80.0; // 횡단보도 감지 반경 (m)
  static const _roadRadius      = 30.0; // 주요 도로 감지 반경 (m)
  static const _distanceFilter  = 40; // 이 거리 이상 이동 시 재계산 (m)

  static const _overpassUrl = 'https://overpass-api.de/api/interpreter';

  final _sensitivityController = StreamController<SensitivityLevel>.broadcast();
  StreamSubscription<Position>? _positionSub;

  /// start/stop마다 올라가는 세대 번호. 느린 조회가 중지·재시작 뒤에 끝났을 때 결과를 버리는 데 쓴다.
  int _generation = 0;

  SensitivityLevel _currentLevel = SensitivityLevel.high;

  /// 위치 + Overpass 결과로 감도를 한 번이라도 정했는지 (false 면 초기값 사용 중)
  bool _resolved = false;

  /// 위치 권한 확인, 현재 위치, 위치 스트림, 주변 조회를 테스트에서 바꿔 끼울 수 있게 열어 둔다.
  /// 인자를 주지 않으면 실제 Geolocator/네트워크를 쓴다.
  GeofenceService({
    Future<bool> Function()? ensurePermission,
    Future<Position> Function()? currentPosition,
    Stream<Position> Function()? positionStream,
    Future<SensitivityLevel> Function(double lat, double lon)? querySensitivity,
  })  : _ensurePermission = ensurePermission ?? _defaultEnsurePermission,
        _currentPosition = currentPosition ?? _defaultCurrentPosition,
        _positionStream = positionStream ?? _defaultPositionStream,
        _querySensitivityOverride = querySensitivity;

  final Future<bool> Function() _ensurePermission;
  final Future<Position> Function() _currentPosition;
  final Stream<Position> Function() _positionStream;
  final Future<SensitivityLevel> Function(double lat, double lon)? _querySensitivityOverride;

  Stream<SensitivityLevel> get sensitivityStream => _sensitivityController.stream;
  SensitivityLevel get currentLevel => _currentLevel;

  static Future<bool> _defaultEnsurePermission() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    return perm == LocationPermission.whileInUse ||
        perm == LocationPermission.always;
  }

  static Future<Position> _defaultCurrentPosition() => Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 6),
        ),
      );

  static Stream<Position> _defaultPositionStream() => Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: _distanceFilter,
        ),
      );

  Future<void> start() async {
    if (!await _ensurePermission()) {
      debugPrint('📍 감도 → ${_currentLevel.name} (초기값 — 위치 권한 없음)');
      return;
    }
    debugPrint('📍 감도 → ${_currentLevel.name} (초기값 — 위치/Overpass 결과 대기 중)');

    final generation = ++_generation;

    // 40m 이상 이동할 때마다 재계산
    _positionSub?.cancel();
    _positionSub = _positionStream().listen((pos) => _update(pos));

    // 시작 시 현재 위치로 한 번 확인한다. GPS(최대 6초)와 네트워크 조회(최대 9초)를 기다리면
    // 감지 시작이 그만큼 늦어지므로 기다리지 않고 백그라운드로 돌린다.
    // 결과는 sensitivityStream으로 전달된다.
    unawaited(_checkCurrentPosition(generation));
  }

  Future<void> _checkCurrentPosition(int generation) async {
    try {
      final pos = await _currentPosition();
      // 조회 중에 중지(또는 다시 시작)됐다면 결과를 쓰지 않는다
      if (generation != _generation) return;
      await _update(pos);
    } catch (e) {
      debugPrint('📍 감도 유지 → ${_currentLevel.name} (초기값 — 현재 위치 확인 실패: $e)');
    }
  }

  /// 위치가 도착할 때마다 올라가는 번호와, 지금까지 적용된 가장 최신 위치의 번호
  int _positionSeq = 0;
  int _appliedSeq = 0;

  Future<void> _update(Position pos) async {
    final generation = _generation;
    final seq = ++_positionSeq;
    final (level, reason) = await _querySensitivity(pos.latitude, pos.longitude);
    // 네트워크 조회가 끝나기 전에 중지됐다면 이미 초기화된 상태를 덮어쓰지 않는다
    // 더 최신 위치의 결과가 이미 적용됐다면 이 결과는 오래된 것이므로 버린다
    if (generation != _generation || seq < _appliedSeq) return;
    if (level == null) {
      // 조회 실패 — 현재 수준 유지
      debugPrint('📍 감도 유지 → ${_currentLevel.name} (${_resolved ? '' : '초기값 — '}$reason)');
      return;
    }
    if (level != _currentLevel || !_resolved) {
      debugPrint('📍 감도 → ${level.name} ($reason)');
    }
    _resolved = true;
    _appliedSeq = seq;
    if (level != _currentLevel) {
      _currentLevel = level;
      _sensitivityController.add(level);
    }
  }

  /// 감도와 그 근거. 조회에 실패하면 level 은 null (호출 측에서 현재 수준 유지)
  Future<(SensitivityLevel?, String)> _querySensitivity(double lat, double lon) async {
    final override = _querySensitivityOverride;
    if (override != null) return (await override(lat, lon), '주입된 조회');

    // OSM Overpass API: 횡단보도(crossing) + 주요 도로(primary~motorway) 조회
    final query = '''
[out:json][timeout:10];
(
  node["highway"="crossing"](around:$_crosswalkRadius,$lat,$lon);
  way["highway"~"^(primary|secondary|tertiary|trunk|motorway)\$"](around:$_roadRadius,$lat,$lon);
);
out center;
''';

    try {
      final res = await http
          .post(Uri.parse(_overpassUrl), body: query)
          .timeout(const Duration(seconds: 9));

      if (res.statusCode != 200) return (null, 'Overpass HTTP ${res.statusCode}');

      final elements = (jsonDecode(res.body)['elements'] as List);

      bool nearCrosswalk = false;
      bool nearRoad      = false;
      double? crosswalkDist;
      double? roadDist;

      for (final el in elements) {
        final tags   = (el['tags'] as Map?)?.cast<String, dynamic>() ?? {};
        final elLat  = (el['lat'] ?? el['center']?['lat']) as num?;
        final elLon  = (el['lon'] ?? el['center']?['lon']) as num?;
        if (elLat == null || elLon == null) continue;

        final dist = _haversine(lat, lon, elLat.toDouble(), elLon.toDouble());

        if (tags['highway'] == 'crossing' && dist <= _crosswalkRadius) {
          nearCrosswalk = true;
          crosswalkDist = dist;
          break; // crosswalk이 최우선
        }
        if (dist <= _roadRadius) {
          nearRoad = true;
          roadDist = min(roadDist ?? dist, dist);
        }
      }

      if (nearCrosswalk) return (SensitivityLevel.high, 'crosswalk ${crosswalkDist!.round()}m');
      if (nearRoad)      return (SensitivityLevel.elevated, 'road ${roadDist!.round()}m');
      return (SensitivityLevel.normal, '주변 횡단보도·주요 도로 없음');
    } catch (e) {
      return (null, 'Overpass 오류: $e'); // 네트워크 오류 시 현재 수준 유지
    }
  }

  /// Haversine 공식으로 두 GPS 좌표 간 거리(m) 계산
  double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLon = (lon2 - lon1) * pi / 180;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) *
            cos(lat2 * pi / 180) *
            sin(dLon / 2) *
            sin(dLon / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  void stop() {
    _generation++; // 진행 중인 조회 결과는 버린다
    _positionSub?.cancel();
    _positionSub = null;
    _currentLevel = SensitivityLevel.normal;
    _resolved = false;
  }

  void dispose() {
    stop();
    _sensitivityController.close();
  }
}
