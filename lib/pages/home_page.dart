import 'dart:async';
import 'package:flutter/material.dart';
import '../widgets/main_card.dart';
import '../widgets/alert_grid.dart';
import '../widgets/recent_list.dart';
import '../services/sound_manager.dart';
import '../services/activity_service.dart';
import '../services/geofence_service.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;
  bool _isListening = false;
  bool _isInitialized = false;
  MotionState _motionState = MotionState.unknown;
  SensitivityLevel _sensitivityLevel = SensitivityLevel.normal;

  final SoundManager _manager = SoundManager();
  StreamSubscription<MotionState>? _motionSubscription;
  StreamSubscription<SensitivityLevel>? _sensitivitySubscription;
  final List<Map<String, dynamic>> _recentLogs = [];

  @override
  void initState() {
    super.initState();
    _initAsync();
    _motionSubscription = _manager.motionStream.listen(
      (state) => setState(() => _motionState = state),
    );
    _sensitivitySubscription = _manager.sensitivityStream.listen(
      (level) => setState(() => _sensitivityLevel = level),
    );
  }

  Future<void> _initAsync() async {
    await _manager.init();
    if (mounted) setState(() => _isInitialized = true);
  }

  Future<void> _onRefresh() async {
    await Future.delayed(const Duration(milliseconds: 800));
    setState(() {});
  }

  Future<void> _toggleListening() async {
    print('🔘 _toggleListening 호출됨, 현재 isListening=$_isListening');
    if (_isListening) {
      await _manager.stopMonitoring();
      _manager.onDetected = null;
      setState(() {
        _motionState = MotionState.unknown;
        _sensitivityLevel = SensitivityLevel.normal;
      });
    } else {
      _manager.onDetected = (event) {
        setState(() {
          _recentLogs.insert(0, {
            'sound':     event.sound,
            'direction': event.direction,
            'time':      DateTime.now(),
          });
          if (_recentLogs.length > 20) _recentLogs.removeLast();
        });
      };
      await _manager.startMonitoring();
    }
    setState(() => _isListening = !_isListening);
  }

  @override
  void dispose() {
    _motionSubscription?.cancel();
    _sensitivitySubscription?.cancel();
    _manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F5FA),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _onRefresh,
          color: const Color(0xFF5B9CF6),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 24),
                buildHeader(),
                const SizedBox(height: 24),
                MainCard(
                  isListening: _isListening,
                  onToggle: _isInitialized ? _toggleListening : null,
                ),
                if (_isListening) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      buildMotionBadge(),
                      const SizedBox(width: 8),
                      buildSensitivityBadge(),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                const Text('감지 항목', style: sectionTitle),
                const SizedBox(height: 12),
                AlertGrid(isListening: _isListening),
                const SizedBox(height: 20),
                const Text('최근 감지', style: sectionTitle),
                const SizedBox(height: 12),
                RecentList(logs: _recentLogs),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: buildBottomNav(),
    );
  }

  static const sectionTitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w700,
    color: Color(0xFF1A1A2E),
  );

  Widget buildSensitivityBadge() {
    final (icon, color) = switch (_sensitivityLevel) {
      SensitivityLevel.high     => (Icons.warning_amber_rounded, const Color(0xFFFF3B30)),
      SensitivityLevel.elevated => (Icons.cell_tower, const Color(0xFFFF9500)),
      SensitivityLevel.normal   => (Icons.graphic_eq, const Color(0xFF8A8FA8)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            _sensitivityLevel.label,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }

  Widget buildMotionBadge() {
    final (icon, label, color) = switch (_motionState) {
      MotionState.moving  => (Icons.directions_walk, '이동 중 · 마이크 활성', const Color(0xFF34C759)),
      MotionState.still   => (Icons.pause_circle_outline, '정지 · 마이크 대기', const Color(0xFFFF9500)),
      MotionState.unknown => (Icons.sensors, '활동 감지 중...', const Color(0xFF8A8FA8)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }

  Widget buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'EarTips',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: Color(0xFF1A1A2E),
              ),
            ),
            SizedBox(height: 2),
            Text(
              '주변 소리를 감지하고 있어요',
              style: TextStyle(fontSize: 13, color: Color(0xFF8A8FA8)),
            ),
          ],
        ),
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: const Icon(Icons.settings_outlined, color: Color(0xFF5B9CF6), size: 22),
        ),
      ],
    );
  }

  Widget buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
        backgroundColor: Colors.transparent,
        elevation: 0,
        selectedItemColor: const Color(0xFF5B9CF6),
        unselectedItemColor: const Color(0xFFB0B8CC),
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11),
        unselectedLabelStyle: const TextStyle(fontSize: 11),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home_outlined), activeIcon: Icon(Icons.home), label: '홈'),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart_outlined), activeIcon: Icon(Icons.bar_chart), label: '통계'),
          BottomNavigationBarItem(icon: Icon(Icons.person_outline), activeIcon: Icon(Icons.person), label: '프로필'),
        ],
      ),
    );
  }
}
