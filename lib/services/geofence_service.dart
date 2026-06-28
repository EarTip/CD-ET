import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

enum SensitivityLevel { normal, elevated, high }

extension SensitivityThreshold on SensitivityLevel {
  double get threshold => switch (this) {
        SensitivityLevel.high     => 0.04, // 횡단보도 80m 이내
        SensitivityLevel.elevated => 0.06, // 주요 도로 30m 이내
        SensitivityLevel.normal   => 0.08, // 일반 구역
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

  SensitivityLevel _currentLevel = SensitivityLevel.high;

  Stream<SensitivityLevel> get sensitivityStream => _sensitivityController.stream;
  SensitivityLevel get currentLevel => _currentLevel;

  Future<bool> _ensurePermission() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    return perm == LocationPermission.whileInUse ||
        perm == LocationPermission.always;
  }

  Future<void> start() async {
    if (!await _ensurePermission()) return;

    // 시작 시 즉시 한 번 확인
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 6),
        ),
      );
      await _update(pos);
    } catch (_) {}

    // 40m 이상 이동할 때마다 재계산
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: _distanceFilter,
      ),
    ).listen((pos) => _update(pos));
  }

  Future<void> _update(Position pos) async {
    final level = await _querySensitivity(pos.latitude, pos.longitude);
    if (level != _currentLevel) {
      _currentLevel = level;
      _sensitivityController.add(level);
    }
  }

  Future<SensitivityLevel> _querySensitivity(double lat, double lon) async {
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

      if (res.statusCode != 200) return _currentLevel;

      final elements = (jsonDecode(res.body)['elements'] as List);

      bool nearCrosswalk = false;
      bool nearRoad      = false;

      for (final el in elements) {
        final tags   = (el['tags'] as Map?)?.cast<String, dynamic>() ?? {};
        final elLat  = (el['lat'] ?? el['center']?['lat']) as num?;
        final elLon  = (el['lon'] ?? el['center']?['lon']) as num?;
        if (elLat == null || elLon == null) continue;

        final dist = _haversine(lat, lon, elLat.toDouble(), elLon.toDouble());

        if (tags['highway'] == 'crossing' && dist <= _crosswalkRadius) {
          nearCrosswalk = true;
          break; // crosswalk이 최우선
        }
        if (dist <= _roadRadius) nearRoad = true;
      }

      if (nearCrosswalk) return SensitivityLevel.high;
      if (nearRoad)      return SensitivityLevel.elevated;
      return SensitivityLevel.normal;
    } catch (_) {
      return _currentLevel; // 네트워크 오류 시 현재 수준 유지
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
    _positionSub?.cancel();
    _positionSub = null;
    _currentLevel = SensitivityLevel.normal;
  }

  void dispose() {
    stop();
    _sensitivityController.close();
  }
}
