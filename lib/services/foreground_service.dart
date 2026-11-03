import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Android에서 앱이 백그라운드로 가도 마이크 감지가 끊기지 않게 하는 포그라운드 서비스.
/// iOS는 UIBackgroundModes(audio)로 유지되므로 사용하지 않는다.
class ForegroundService {
  static bool get _supported => Platform.isAndroid;

  static void init() {
    if (!_supported) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'eartips_sound',
        channelName: 'EarTips 소리 감지',
        channelDescription: '소리 감지 서비스가 실행 중입니다',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  /// 서비스를 시작한다. 서비스가 필요 없는 플랫폼(iOS)이거나 이미 실행 중이면 true,
  /// 시작하지 못했으면 false. 호출한 쪽이 사용자에게 알릴 수 있도록 결과를 돌려준다.
  /// (실패해도 앱이 떠 있는 동안의 감지는 계속 동작해야 하므로 예외로 던지지 않는다)
  static Future<bool> start() async {
    if (!_supported) return true;
    try {
      if (await FlutterForegroundTask.isRunningService) return true;
      final result = await FlutterForegroundTask.startService(
        serviceId: 100,
        notificationTitle: 'EarTips 감지 중',
        notificationText: '소리를 분석하고 있어요',
        callback: _startCallback,
      );
      if (result is ServiceRequestFailure) {
        debugPrint('포그라운드 서비스를 시작하지 못했습니다: ${result.error}');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('포그라운드 서비스를 시작하지 못했습니다: $e');
      return false;
    }
  }

  /// 서비스를 중지한다. 서비스가 필요 없는 플랫폼(iOS)이거나 이미 꺼져 있으면 true,
  /// 중지하지 못해 서비스(알림·wake lock)가 남아 있을 수 있으면 false.
  static Future<bool> stop() async {
    if (!_supported) return true;
    try {
      final result = await FlutterForegroundTask.stopService();
      // 실행 중이 아니었다면 이미 원하는 상태다
      if (result is ServiceRequestFailure && result.error is! ServiceNotStartedException) {
        debugPrint('포그라운드 서비스를 중지하지 못했습니다: ${result.error}');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('포그라운드 서비스를 중지하지 못했습니다: $e');
      return false;
    }
  }
}

@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveTaskHandler());
}

/// 서비스가 프로세스를 살려두는 역할만 하므로 처리할 이벤트가 없다.
class _KeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // 시스템이 서비스를 다시 시작한 경우(앱 프로세스가 종료된 뒤)에는 감지가 돌고 있지 않다.
    // 알림과 wake lock만 남지 않도록 스스로 중지한다. 감지는 사용자가 다시 켜야 한다.
    if (starter == TaskStarter.system) {
      debugPrint('시스템이 재시작한 포그라운드 서비스를 중지합니다 (감지 상태 없음)');
      await FlutterForegroundTask.stopService();
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}
