import 'package:flutter/material.dart';

class AlertGrid extends StatelessWidget {
  final bool isListening;
  const AlertGrid({super.key, required this.isListening});

  @override
  Widget build(BuildContext context) {
    final items = [
      {'icon': Icons.car_crash_outlined, 'label': '경적', 'enabled': true},
      {'icon': Icons.emergency_outlined, 'label': '사이렌', 'enabled': true},
      {'icon': Icons.record_voice_over_outlined, 'label': '내 이름', 'enabled': false},
      {'icon': Icons.directions_car_outlined, 'label': '급브레이크', 'enabled': true},
    ];

    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.6,
      children: items.map((item) => _AlertCard(item: item, isListening: isListening)).toList(),
    );
  }
}

class _AlertCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool isListening;
  const _AlertCard({required this.item, required this.isListening});

  @override
  Widget build(BuildContext context) {
    final bool active = isListening && (item['enabled'] as bool);
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
              color: active
                  ? const Color(0xFF5B9CF6).withValues(alpha: 0.12)
                  : const Color(0xFFF0F0F0),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              item['icon'] as IconData,
              color: active ? const Color(0xFF5B9CF6) : const Color(0xFFB0B0B0),
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
                    color: active ? const Color(0xFF1A1A2E) : const Color(0xFFB0B0B0),
                  ),
                ),
                Text(
                  active ? '감지 중' : '꺼짐',
                  style: TextStyle(
                    fontSize: 11,
                    color: active ? const Color(0xFF5B9CF6) : const Color(0xFFB0B0B0),
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
