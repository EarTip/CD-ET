import 'package:eartips/services/pose_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PoseTracker 샘플 만료', () {
    late Duration now;
    late PoseTracker tracker;

    setUp(() {
      now = Duration.zero;
      tracker = PoseTracker(uptime: () => now);
    });

    test('샘플이 없으면 null', () {
      expect(tracker.current, isNull);
    });

    test('최근 샘플이면 자세를 돌려준다', () {
      tracker.addSample(0, 6.9, 6.9); // 화면 보며 걷는 자세 (약 45°)
      expect(tracker.current, isNotNull);
      expect(tracker.current!.canEstimateDirection, isTrue);
    });

    test('유효 기간 안에서는 자세가 유지된다', () {
      tracker.addSample(0, 6.9, 6.9);
      now += PoseTracker.maxSampleAge;
      expect(tracker.current, isNotNull);
    });

    test('샘플이 끊겨 유효 기간을 넘으면 null (옛 자세로 방향을 내지 않음)', () {
      tracker.addSample(0, 6.9, 6.9);
      now += PoseTracker.maxSampleAge + const Duration(milliseconds: 1);
      expect(tracker.current, isNull);
    });

    test('끊겼다가 다시 샘플이 오면 옛 값과 섞이지 않고 새 자세로 시작한다', () {
      tracker.addSample(0, 9.8, 0); // 세워 듦 (앙각 90°)
      now += const Duration(seconds: 5);
      tracker.addSample(0, 0, 9.8); // 책상 위 (앙각 0°)
      expect(tracker.current!.axisElevationDeg, closeTo(0, 1e-6));
    });

    test('연속으로 들어오는 샘플은 저역통과로 평활화된다', () {
      tracker.addSample(0, 9.8, 0);
      now += const Duration(milliseconds: 66);
      tracker.addSample(0, 0, 9.8);
      // alpha=0.1이라 한 번의 급변으로는 자세가 크게 바뀌지 않는다
      expect(tracker.current!.axisElevationDeg, greaterThan(60));
    });
  });
}
