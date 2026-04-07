import 'package:vibration/vibration.dart';
import 'sound_detector.dart';

class HapticService {
  Future<void> playPattern(DetectedSound sound) async {
    final hasVibrator = await Vibration.hasVibrator() ?? false;
    if (!hasVibrator) return;

    switch (sound) {
      case DetectedSound.horn:
        Vibration.vibrate(pattern: [0, 100, 200, 100]);
      case DetectedSound.siren:
        Vibration.vibrate(pattern: [0, 600]);
      case DetectedSound.brake:
        Vibration.vibrate(pattern: [0, 60, 60, 60, 60, 60]);
      case DetectedSound.none:
        break;
    }
  }
}