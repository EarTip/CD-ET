import '../services/sound_detector.dart';
import '../services/tdoa_analyzer.dart';

class DetectionLog {
  final int? id;
  final DetectedSound sound;
  final SoundDirection? direction;
  final DateTime time;

  DetectionLog({
    this.id,
    required this.sound,
    this.direction,
    required this.time,
  });

  Map<String, dynamic> toMap() => {
    'sound': sound.name,
    'direction': direction?.name,
    'time': time.millisecondsSinceEpoch,
  };

  factory DetectionLog.fromMap(Map<String, dynamic> m) => DetectionLog(
    id: m['id'],
    sound: DetectedSound.values.byName(m['sound']),
    direction: m['direction'] != null
        ? SoundDirection.values.byName(m['direction'])
        : null,
    time: DateTime.fromMillisecondsSinceEpoch(m['time']),
  );
}
