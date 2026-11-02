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

  static Future<void> start() async {
    if (!_supported) return;
    try {
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.startService(
        serviceId: 100,
        notificationTitle: 'EarTips 감지 중',
        notificationText: '소리를 분석하고 있어요',
        callback: _startCallback,
      );
    } catch (e) {
      // 서비스 시작에 실패해도 앱이 떠 있는 동안의 감지는 계속 동작해야 한다
      debugPrint('포그라운드 서비스를 시작하지 못했습니다: $e');
    }
  }

  static Future<void> stop() async {
    if (!_supported) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      debugPrint('포그라운드 서비스를 중지하지 못했습니다: $e');
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
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}
