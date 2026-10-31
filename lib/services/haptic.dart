import 'package:flutter/services.dart';
import 'sound_detector.dart';

class HapticService {
  static const _channel = MethodChannel('haptic_channel');

  Future<void> playPattern(DetectedSound sound) async {
    print('🎯 playPattern 호출됨: $sound');  // 추가
    final method = switch (sound) {
      DetectedSound.siren => 'siren',
      DetectedSound.horn  => 'horn',
      DetectedSound.brake => 'brake',
      DetectedSound.bicycle => 'horn', // 전용 네이티브 패턴이 없어 경적 패턴 재사용
      DetectedSound.none  => null,
    };

    if (method != null) {
      await _channel.invokeMethod(method);
    }
  }
}