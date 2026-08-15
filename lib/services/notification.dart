import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'sound_detector.dart';

class NotificationService {
  final _notifications = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    await Permission.notification.request();

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _notifications.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );

    await _notifications
        .resolvePlatformSpecificImplementation
            <IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);

    _initialized = true;
  }

  Future<void> showSoundAlert(DetectedSound sound) async {
    print('showSoundAlert 호출됨: $sound / initialized: $_initialized');
    if (!_initialized) return;
    String title;
    String body;

    switch (sound) {
      case DetectedSound.horn:
        title = '⚠️ 경적 감지';
        body = '주변에 경적 소리가 감지되었습니다';
      case DetectedSound.siren:
        title = '🚨 사이렌 감지';
        body = '긴급차량 사이렌이 감지되었습니다';
      case DetectedSound.brake:
        title = '🛑 급정거 감지';
        body = '주변에 급정거 소리가 감지되었습니다';
      case DetectedSound.none:
        return;
    }

    await showNotification(title, body);
  }

  Future<void> showNotification(String title, String body) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'danger_channel',
        '위험 감지 알림',
        channelDescription: '경적·사이렌 등 위험 소리 감지 시 표시되는 알림',
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
    await _notifications.show(0, title, body, details);
  }
}