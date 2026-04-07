import 'dart:async';
import 'package:flutter/material.dart';
import '../widgets/main_card.dart';
import '../widgets/alert_grid.dart';
import '../widgets/recent_list.dart';
import '../services/sound_manager.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;
  bool _isListening = false;

  final SoundManager _manager = SoundManager();
  StreamSubscription? _subscription;
  final List<Map<String, dynamic>> _recentLogs = [];

  @override
  void initState() {
    super.initState();
    _manager.init();
  }

  Future<void> _onRefresh() async {
    await Future.delayed(const Duration(milliseconds: 800));
    setState(() {});
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      _manager.stopMonitoring();
      _subscription?.cancel();
    } else {
      _manager.startMonitoring();
      _subscription = _manager.detectionStream.listen((sound) {
        setState(() {
          _recentLogs.insert(0, {
            'sound': sound,
            'time': DateTime.now(),
          });
          if (_recentLogs.length > 20) _recentLogs.removeLast();
        });
      });
    }
    setState(() => _isListening = !_isListening);
  }

  @override
  void dispose() {
    _subscription?.cancel();
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
                _buildHeader(),
                const SizedBox(height: 24),
                MainCard(
                  isListening: _isListening,
                  onToggle: _toggleListening,
                ),
                const SizedBox(height: 20),
                const Text('감지 항목', style: _sectionTitle),
                const SizedBox(height: 12),
                AlertGrid(isListening: _isListening),
                const SizedBox(height: 20),
                const Text('최근 감지', style: _sectionTitle),
                const SizedBox(height: 12),
                RecentList(logs: _recentLogs),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  static const _sectionTitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w700,
    color: Color(0xFF1A1A2E),
  );

  Widget _buildHeader() {
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

  Widget _buildBottomNav() {
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