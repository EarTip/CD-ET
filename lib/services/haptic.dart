import 'package:flutter/services.dart';
import 'sound_detector.dart';

class HapticService {
  static const _channel = MethodChannel('haptic_channel');

  Future<void> playPattern(DetectedSound sound) async {
    final method = switch (sound) {
      DetectedSound.siren => 'siren',
      DetectedSound.horn  => 'horn',
      DetectedSound.brake => 'brake',
      // DetectedSound.name  => 'name',   -- 아직 sound_detector.dart에 name 구현 안 함
      DetectedSound.none  => null,
    };

    if (method != null) {
      await _channel.invokeMethod(method);
    }
  }
}