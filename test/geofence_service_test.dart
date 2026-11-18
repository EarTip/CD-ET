import 'dart:async';

import 'package:eartips/services/geofence_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

Position _position() => Position(
      latitude: 37.5,
      longitude: 127.0,
      timestamp: DateTime(2026),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

void main() {
  late StreamController<Position> positionStream;
  late Completer<Position> currentPosition;
  late Completer<SensitivityLevel> query;
  late int queryCalls;
  late bool permitted;
  late GeofenceService service;

  setUp(() {
    // 실제 getPositionStream()은 호출마다 새 스트림을 주므로 여러 번 구독할 수 있어야 한다
    positionStream = StreamController<Position>.broadcast();
    currentPosition = Completer<Position>();
    query = Completer<SensitivityLevel>();
    queryCalls = 0;
    permitted = true;
    service = GeofenceService(
      ensurePermission: () async => permitted,
      currentPosition: () => currentPosition.future,
      positionStream: () => positionStream.stream,
      querySensitivity: (lat, lon) {
        queryCalls++;
        return query.future;
      },
    );
  });

  tearDown(() async {
    service.dispose();
    await positionStream.close();
  });

  group('GeofenceService.start', () {
    test('처음 위치·네트워크 조회가 끝나지 않아도 start()가 바로 끝난다', () async {
      // currentPosition/query를 완료시키지 않았다. 기다리면 이 await가 끝나지 않는다.
      await service.start().timeout(const Duration(seconds: 1));
      expect(positionStream.hasListener, isTrue);
      expect(queryCalls, 0);
    });

    test('조회가 끝나면 sensitivityStream으로 결과를 전달한다', () async {
      final levels = <SensitivityLevel>[];
      service.sensitivityStream.listen(levels.add);

      await service.start();
      currentPosition.complete(_position());
      await pumpEventQueue();
      expect(levels, isEmpty); // 네트워크 조회가 아직 끝나지 않음

      query.complete(SensitivityLevel.elevated);
      await pumpEventQueue();
      expect(levels, [SensitivityLevel.elevated]);
      expect(service.currentLevel, SensitivityLevel.elevated);
    });

    test('위치 권한이 없으면 구독도 조회도 하지 않는다', () async {
      permitted = false;
      await service.start();
      currentPosition.complete(_position());
      await pumpEventQueue();
      expect(positionStream.hasListener, isFalse);
      expect(queryCalls, 0);
    });
  });

  group('GeofenceService 중지 후 늦게 끝난 조회', () {
    test('위치를 얻기 전에 중지하면 조회하지 않고 결과도 쓰지 않는다', () async {
      final levels = <SensitivityLevel>[];
      service.sensitivityStream.listen(levels.add);

      await service.start();
      service.stop();
      currentPosition.complete(_position());
      query.complete(SensitivityLevel.high);
      await pumpEventQueue();

      expect(queryCalls, 0);
      expect(levels, isEmpty);
      expect(service.currentLevel, SensitivityLevel.normal);
      expect(positionStream.hasListener, isFalse);
    });

    test('네트워크 조회 중에 중지하면 끝난 결과가 초기화된 상태를 덮어쓰지 않는다', () async {
      final levels = <SensitivityLevel>[];
      service.sensitivityStream.listen(levels.add);

      await service.start();
      currentPosition.complete(_position());
      await pumpEventQueue();
      expect(queryCalls, 1);

      service.stop();
      query.complete(SensitivityLevel.high);
      await pumpEventQueue();

      expect(levels, isEmpty);
      expect(service.currentLevel, SensitivityLevel.normal);
    });

    test('중지 뒤 다시 시작하면 이전 시작의 조회 결과는 버리고 새 결과만 쓴다', () async {
      final levels = <SensitivityLevel>[];
      service.sensitivityStream.listen(levels.add);

      // 첫 번째 시작: 조회가 오래 걸린다
      final firstQuery = query;
      await service.start();
      currentPosition.complete(_position());
      await pumpEventQueue();
      service.stop();

      // 두 번째 시작: 새 조회
      query = Completer<SensitivityLevel>();
      currentPosition = Completer<Position>();
      await service.start();
      currentPosition.complete(_position());
      await pumpEventQueue();

      firstQuery.complete(SensitivityLevel.high); // 이전 시작의 늦은 결과
      await pumpEventQueue();
      expect(levels, isEmpty);

      query.complete(SensitivityLevel.elevated);
      await pumpEventQueue();
      expect(levels, [SensitivityLevel.elevated]);
    });
  });

  group('GeofenceService 겹친 조회', () {
    late List<Completer<SensitivityLevel>> queries;
    late GeofenceService overlapping;
    late List<SensitivityLevel> levels;

    setUp(() async {
      queries = [];
      levels = [];
      overlapping = GeofenceService(
        ensurePermission: () async => true,
        currentPosition: () => Completer<Position>().future, // 끝나지 않음
        positionStream: () => positionStream.stream,
        querySensitivity: (lat, lon) {
          final c = Completer<SensitivityLevel>();
          queries.add(c);
          return c.future;
        },
      );
      addTearDown(overlapping.dispose);
      overlapping.sensitivityStream.listen(levels.add);
      await overlapping.start();
      positionStream.add(_position()); // 조회 A
      positionStream.add(_position()); // 조회 B
      await pumpEventQueue();
      expect(queries.length, 2);
    });

    test('더 최신 위치의 결과가 먼저 적용되면 늦게 끝난 오래된 결과는 버린다', () async {
      queries[1].complete(SensitivityLevel.elevated); // B
      await pumpEventQueue();
      queries[0].complete(SensitivityLevel.high); // A (오래된 위치)
      await pumpEventQueue();

      expect(levels, [SensitivityLevel.elevated]);
      expect(overlapping.currentLevel, SensitivityLevel.elevated);
    });

    test('더 최신 조회가 실패해도 먼저 요청한 조회의 성공 결과는 반영한다', () async {
      queries[1].completeError(Exception('HTTP 오류')); // B 실패
      await pumpEventQueue();
      expect(levels, isEmpty);
      expect(overlapping.currentLevel, SensitivityLevel.high); // 초기값 유지

      queries[0].complete(SensitivityLevel.normal); // A 성공
      await pumpEventQueue();

      expect(levels, [SensitivityLevel.normal]);
      expect(overlapping.currentLevel, SensitivityLevel.normal);
    });
  });
}
