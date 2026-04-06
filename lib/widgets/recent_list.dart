import 'package:flutter/material.dart';
import '../services/sound_detector.dart';

class RecentList extends StatelessWidget {
  final List<Map<String, dynamic>> logs;
  const RecentList({super.key, required this.logs});

  @override
  Widget build(BuildContext context) {
    if (logs.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 32),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Column(
          children: [
            Icon(Icons.hearing_disabled_outlined, color: Color(0xFFB0B8CC), size: 36),
            SizedBox(height: 8),
            Text(
              '아직 감지된 소리가 없어요',
              style: TextStyle(fontSize: 13, color: Color(0xFFB0B8CC)),
            ),
          ],
        ),
      );
    }

    return Column(
      children: logs.map((log) {
        final sound = log['sound'] as DetectedSound;
        final time = log['time'] as DateTime;
        final info = _soundInfo(sound);

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: info.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(info.icon, color: info.color, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  info.label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ),
              Text(
                _timeAgo(time),
                style: const TextStyle(fontSize: 12, color: Color(0xFF8A8FA8)),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  _SoundInfo _soundInfo(DetectedSound sound) {
    switch (sound) {
      case DetectedSound.horn:
        return _SoundInfo(Icons.car_crash_outlined, '경적 감지됨', const Color(0xFFFF6B6B));
      case DetectedSound.siren:
        return _SoundInfo(Icons.emergency_outlined, '사이렌 감지됨', const Color(0xFFFFB347));
      case DetectedSound.brake:
        return _SoundInfo(Icons.directions_car_outlined, '급브레이크 감지됨', const Color(0xFFFF9F43));
      case DetectedSound.none:
        return _SoundInfo(Icons.volume_off_outlined, '알 수 없음', const Color(0xFFB0B8CC));
    }
  }

  String _timeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inSeconds < 60) return '방금 전';
    if (diff.inMinutes < 60) return '${diff.inMinutes}분 전';
    return '${diff.inHours}시간 전';
  }
}

class _SoundInfo {
  final IconData icon;
  final String label;
  final Color color;
  _SoundInfo(this.icon, this.label, this.color);
}
