import 'package:flutter/material.dart';
import '../services/settings_service.dart';
import '../services/sound_detector.dart';

class AlertGrid extends StatelessWidget {
  final bool isListening;

  /// 감지는 켜져 있지만 마이크가 실제로는 대기 중인 상태
  /// (정지 상태이거나, 이어폰 전용 모드에서 이어폰 미연결)
  final bool isWaiting;

  const AlertGrid({
    super.key,
    required this.isListening,
    this.isWaiting = false,
  });

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;

    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final items = [
          {'icon': Icons.car_crash_outlined, 'label': '경적', 'enabled': settings.isSoundEnabled(DetectedSound.horn)},
          {'icon': Icons.emergency_outlined, 'label': '사이렌', 'enabled': settings.isSoundEnabled(DetectedSound.siren)},
          {'icon': Icons.record_voice_over_outlined, 'label': '내 이름', 'enabled': false},
          {'icon': Icons.directions_car_outlined, 'label': '급브레이크', 'enabled': settings.isSoundEnabled(DetectedSound.brake)},
        ];

        return GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.6,
          children: items
              .map((item) => _AlertCard(item: item, isListening: isListening, isWaiting: isWaiting))
              .toList(),
        );
      },
    );
  }
}

class _AlertCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool isListening;
  final bool isWaiting;
  const _AlertCard({required this.item, required this.isListening, required this.isWaiting});

  @override
  Widget build(BuildContext context) {
    final bool enabled = item['enabled'] as bool;
    final bool on = isListening && enabled; // 이 항목이 활성화되어 동작 중
    final bool detecting = on && !isWaiting; // 실제로 감지 중
    final bool waiting = on && isWaiting; // 마이크 대기 중
    // 상태별 색상: 감지 중(파랑) · 마이크 대기(주황) · 꺼짐(회색)
    const Color blue = Color(0xFF5B9CF6);
    const Color amber = Color(0xFFFF9500);
    const Color gray = Color(0xFFB0B0B0);

    final Color accent = detecting ? blue : (waiting ? amber : gray);
    final Color iconBg = detecting
        ? blue.withValues(alpha: 0.12)
        : (waiting ? amber.withValues(alpha: 0.12) : const Color(0xFFF0F0F0));
    final Color titleColor = on ? const Color(0xFF1A1A2E) : gray;

    final String statusLabel = detecting ? '감지 중' : (waiting ? '마이크 대기' : '꺼짐');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              item['icon'] as IconData,
              color: accent,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  item['label'] as String,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: titleColor,
                  ),
                ),
                Text(
                  statusLabel,
                  style: TextStyle(
                    fontSize: 11,
                    color: accent,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
