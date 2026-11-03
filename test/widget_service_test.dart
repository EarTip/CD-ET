import 'dart:math';

import 'package:eartips/services/widget_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final token = 'a' * 64;

  Uri uri(String query, {String scheme = 'eartips', String host = 'widget'}) =>
      Uri.parse('$scheme://$host?$query');

  group('위젯 URL 검증', () {
    test('올바른 비밀값이 있는 시작/중지 요청은 허용', () {
      expect(WidgetService.isAuthorizedUri(uri('action=start&homeWidget&token=$token'), token), isTrue);
      expect(WidgetService.isAuthorizedUri(uri('action=stop&homeWidget&token=$token'), token), isTrue);
    });

    test('비밀값이 없는 외부 링크는 거부', () {
      expect(WidgetService.isAuthorizedUri(uri('action=start&homeWidget'), token), isFalse);
      expect(WidgetService.isAuthorizedUri(uri('action=stop&homeWidget'), token), isFalse);
    });

    test('비밀값이 다르면 거부', () {
      expect(WidgetService.isAuthorizedUri(uri('action=start&homeWidget&token=${'b' * 64}'), token), isFalse);
      // 길이가 다른 값
      expect(WidgetService.isAuthorizedUri(uri('action=start&homeWidget&token=${'a' * 63}'), token), isFalse);
      expect(WidgetService.isAuthorizedUri(uri('action=start&homeWidget&token='), token), isFalse);
    });

    test('앱의 비밀값이 없거나 형식이 잘못되면 요청을 거부 (검증을 우회하지 않음)', () {
      // 초기화/공유 실패로 expected가 없는 경우
      expect(WidgetService.isAuthorizedUri(uri('action=start&homeWidget&token=$token'), null), isFalse);
      expect(WidgetService.isAuthorizedUri(uri('action=start&homeWidget&token='), ''), isFalse);
      // 요청의 값이 저장된 (잘못된) 값과 같아도 형식이 틀리면 거부
      expect(WidgetService.isAuthorizedUri(uri('action=start&homeWidget&token=abc'), 'abc'), isFalse);
      expect(WidgetService.isAuthorizedUri(uri('action=start&homeWidget&token=${'A' * 64}'), 'A' * 64), isFalse);
    });

    test('허용하지 않은 host/scheme/action은 비밀값이 맞아도 거부', () {
      final q = 'homeWidget&token=$token';
      expect(WidgetService.isAuthorizedUri(uri('action=start&$q', host: 'other'), token), isFalse);
      expect(WidgetService.isAuthorizedUri(uri('action=start&$q', scheme: 'https'), token), isFalse);
      expect(WidgetService.isAuthorizedUri(uri('action=toggle&$q'), token), isFalse);
      expect(WidgetService.isAuthorizedUri(uri('action=&$q'), token), isFalse);
      expect(WidgetService.isAuthorizedUri(uri(q), token), isFalse);
    });
  });

  group('비밀값 생성', () {
    test('소문자 hex 64자(32바이트)', () {
      expect(WidgetService.generateToken(), matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('생성할 때마다 다른 값', () {
      final values = {for (var i = 0; i < 50; i++) WidgetService.generateToken()};
      expect(values.length, 50);
    });

    test('주입한 난수기로 결정적으로 만들 수 있음 (형식 확인용)', () {
      final a = WidgetService.generateToken(Random(1));
      final b = WidgetService.generateToken(Random(1));
      expect(a, b);
    });
  });
}
