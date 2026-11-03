import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';

/// 홈 화면 위젯(Android/iOS)과 앱 사이의 상태 공유와 탭 처리.
///
/// - Android: 위젯 탭은 네이티브가 `eartips/widget` 채널로 'toggle'을 보내거나,
///   앱이 꺼져 있으면 시작 요청을 대기 액션으로 남긴다 ([consumePendingAction]).
/// - iOS: 위젯 탭은 `eartips://widget?action=start|stop&homeWidget` URL로 앱을 연다.
///   백그라운드에서 마이크를 시작할 수 없어서 끄기도 앱을 연 뒤 처리한다.
class WidgetService {
  static const _channel = MethodChannel('eartips/widget');

  /// iOS 앱과 위젯 확장이 공유하는 App Group. Xcode 설정과 같아야 한다.
  static const appGroupId = 'group.com.example.eartips';
  static const _listeningKey = 'is_listening';
  static const _androidProvider = 'com.example.eartips.SoundWidgetProvider';
  static const _iosWidgetKind = 'SoundWidget';

  /// 위젯에서 감지 시작/중지 요청이 오면 호출된다. (start: true=시작, false=중지)
  static Future<void> Function(bool start)? onToggleRequest;

  static StreamSubscription<Uri?>? _clickSubscription;

  /// 홈 화면이 준비되기 전에 들어온 iOS 위젯 요청. 준비된 뒤 [handleLaunchRequest]에서 처리한다.
  static Uri? _pendingUri;

  static Future<void> init() async {
    if (Platform.isIOS) {
      await HomeWidget.setAppGroupId(appGroupId);
      // 앱이 실행 중일 때 스플래시 화면에서 위젯을 탭해도 요청이 버려지지 않도록 미리 구독한다
      _listenForClicks();
    }
  }

  static void _listenForClicks() {
    _clickSubscription ??= HomeWidget.widgetClicked.listen(_onClick);
  }

  static void _onClick(Uri? uri) {
    if (onToggleRequest == null) {
      _pendingUri = uri;
      return;
    }
    unawaited(_handleUri(uri));
  }

  /// 앱 시작 직후 한 번 호출. 위젯으로 앱이 켜졌다면 그 요청을 처리한다.
  static Future<void> handleLaunchRequest() async {
    if (Platform.isAndroid) {
      final action = await _consumePendingAction();
      try {
        if (action == 'start') await onToggleRequest?.call(true);
      } finally {
        // 성공/실패와 무관하게 투명 화면은 닫는다 (터치를 막은 채 남지 않도록)
        await notifyReady();
      }
    } else if (Platform.isIOS) {
      final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
      await _handleUri(uri);
      // 홈 화면이 뜨기 전에 구독으로 먼저 받아 둔 요청 (콜드 스타트 URL과 같으면 중복이므로 건너뜀)
      final pending = _pendingUri;
      _pendingUri = null;
      if (pending != null && pending != uri) await _handleUri(pending);
    }
  }

  /// 앱 실행 중 들어오는 위젯 요청을 듣기 시작한다.
  static void listen() {
    if (Platform.isAndroid) {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'toggle') {
          await onToggleRequest?.call(call.arguments == 'start');
        }
      });
    } else if (Platform.isIOS) {
      _listenForClicks();
    }
  }

  static void dispose() {
    _clickSubscription?.cancel();
    _clickSubscription = null;
    _pendingUri = null;
    if (Platform.isAndroid) _channel.setMethodCallHandler(null);
  }

  /// 감지 상태를 위젯에 반영한다.
  static Future<void> publishListening(bool listening) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      await HomeWidget.saveWidgetData<bool>(_listeningKey, listening);
      await HomeWidget.updateWidget(
        qualifiedAndroidName: _androidProvider,
        iOSName: _iosWidgetKind,
      );
    } catch (e) {
      debugPrint('위젯 상태를 갱신하지 못했습니다: $e');
    }
  }

  /// 위젯으로 앱을 띄운 경우, 감지 시작을 마쳤으니 투명 화면을 닫아도 된다고 알린다. (Android)
  static Future<void> notifyReady() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('readyToBackground');
    } catch (e) {
      debugPrint('위젯 화면 종료 요청에 실패했습니다: $e');
    }
  }

  static Future<String?> _consumePendingAction() async {
    try {
      return await _channel.invokeMethod<String>('consumePendingAction');
    } catch (e) {
      debugPrint('위젯 대기 액션을 가져오지 못했습니다: $e');
      return null;
    }
  }

  /// iOS 위젯은 표시 중인 상태를 기준으로 "시작"/"중지"를 요청한다.
  /// 이미 그 상태면 앱만 열린다. (위젯 표시가 오래돼 실제와 다른 경우에도 안전하다)
  static Future<void> _handleUri(Uri? uri) async {
    if (uri == null || uri.host != 'widget') return;
    switch (uri.queryParameters['action']) {
      case 'start':
        await onToggleRequest?.call(true);
      case 'stop':
        await onToggleRequest?.call(false);
    }
  }
}
