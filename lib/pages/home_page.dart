import 'dart:async';
import 'package:flutter/material.dart';
import '../widgets/main_card.dart';
import '../widgets/alert_grid.dart';
import '../widgets/recent_list.dart';
import '../services/sound_manager.dart';
import '../services/foreground_service.dart';
import '../services/widget_service.dart';
import '../services/activity_service.dart';
import '../services/geofence_service.dart';
import '../services/indoor_outdoor_service.dart';
import '../models/detection_log.dart';
import '../services/log_repository.dart';
import '../services/tdoa_analyzer.dart';
import 'stats_page.dart';
import '../services/settings_service.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;
  bool _isListening = false;
  bool _isInitialized = false;
  /// start/stopMonitoring 완료 전 재클릭으로 중복 실행되는 것을 막는 가드
  bool _isToggling = false;
  MotionState _motionState = MotionState.unknown;
  SensitivityLevel _sensitivityLevel = SensitivityLevel.normal;
  IndoorOutdoorState _indoorState = IndoorOutdoorState.indoor;
  bool _earphoneConnected = false;

  final SoundManager _manager = SoundManager();
  final SettingsService _settings = SettingsService.instance;
  StreamSubscription<MotionState>? _motionSubscription;
  StreamSubscription<SensitivityLevel>? _sensitivitySubscription;
  StreamSubscription<IndoorOutdoorState>? _indoorOutdoorSubscription;
  StreamSubscription<bool>? _earphoneSubscription;
  final List<Map<String, dynamic>> _recentLogs = [];

  /// SoundManager 초기화 완료. 위젯 요청은 이 이후에만 처리한다.
  late final Future<void> _ready;

  @override
  void initState() {
    super.initState();
    _ready = _initAsync();
    WidgetService.onToggleRequest = _onWidgetToggleRequest;
    WidgetService.listen();
    unawaited(_syncWidgetOnStart());
    _loadRecentLogs();
    _motionSubscription = _manager.motionStream.listen(
      (state) => setState(() => _motionState = state),
    );
    _sensitivitySubscription = _manager.sensitivityStream.listen(
      (level) => setState(() => _sensitivityLevel = level),
    );
    _indoorOutdoorSubscription = _manager.indoorOutdoorStream.listen(
      (state) => setState(() => _indoorState = state),
    );
    _earphoneSubscription = _manager.earphoneStream.listen(
      (connected) => setState(() => _earphoneConnected = connected),
    );
  }

  /// 감지는 켜져 있지만 마이크가 실제로는 대기 상태인지 여부.
  /// 정지 상태이거나, 이어폰 전용 모드에서 이어폰이 연결되지 않은 경우.
  /// 데모 모드에서는 정지 상태여도 마이크가 켜져 있다.
  bool get _micWaiting =>
      _isListening &&
      ((_motionState == MotionState.still && !_settings.demoMode) ||
          (_settings.earphoneOnly && !_earphoneConnected));

  Future<void> _initAsync() async {
    await _manager.init();
    if (mounted) setState(() => _isInitialized = true);
  }

  /// 위젯의 표시 상태를 실제 상태로 맞추고(앱이 강제 종료됐다면 "감지 중"이 남아 있을 수 있음),
  /// 위젯으로 앱이 켜졌다면 그 요청을 처리한다.
  Future<void> _syncWidgetOnStart() async {
    try {
      await _ready;
      await WidgetService.publishListening(_isListening);
      await WidgetService.handleLaunchRequest();
    } catch (e) {
      // unawaited로 실행되므로 여기서 잡지 않으면 처리되지 않은 비동기 오류가 된다
      debugPrint('위젯 초기 동기화에 실패했습니다: $e');
    }
  }

  /// 위젯(Android 채널, iOS URL, 앱 시작 직후 요청)에서 온 감지 시작/중지 요청.
  /// 실패해도 호출한 쪽(unawaited/채널 핸들러)으로 예외를 넘기지 않고 사용자에게 알린다.
  Future<void> _onWidgetToggleRequest(bool start) async {
    try {
      await _ready;
      if (!mounted || start == _isListening) return;
      await _toggleListening();
    } catch (e) {
      debugPrint('위젯 요청으로 감지를 ${start ? '시작' : '중지'}하지 못했습니다: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            start ? '감지를 시작하지 못했습니다. 다시 시도해 주세요.' : '감지를 중지하지 못했습니다. 다시 시도해 주세요.',
          ),
        ),
      );
    }
  }

  Future<void> _loadRecentLogs() async {
    try {
      final logs = await LogRepository.instance.recent();
      if (mounted) {
        setState(() {
          _recentLogs.clear();
          _recentLogs.addAll(
            logs.map(
              (l) => {
                'sound': l.sound,
                'direction': l.direction ?? SoundDirection.unknown,
                'time': l.time,
              },
            ),
          );
        });
      }
    } catch (e) {
      debugPrint('최근 감지 기록을 불러오지 못했습니다: $e');
    }
  }

  Future<void> _onRefresh() async {
    await _loadRecentLogs();
  }

  Future<void> _toggleListening() async {
    print('🔘 _toggleListening 호출됨, 현재 isListening=$_isListening');
    if (_isToggling) return;
    _isToggling = true;
    try {
      if (_isListening) {
        await _manager.stopMonitoring();
        final serviceStopped = await ForegroundService.stop();
        _manager.onDetected = null;
        setState(() {
          _motionState = MotionState.unknown;
          _sensitivityLevel = SensitivityLevel.normal;
          _indoorState = IndoorOutdoorState.indoor;
        });
        // 마이크 감지는 이미 꺼졌으므로 상태는 중지로 바꾸되, 서비스가 남았다면 알린다
        if (!serviceStopped && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('감지는 중지됐지만 알림이 남아 있을 수 있어요. 앱을 완전히 종료해 주세요.')),
          );
        }
      } else {
        _manager.onDetected = (event) async {
          try {
            await LogRepository.instance.insert(
              DetectionLog(
                sound: event.sound,
                direction: event.direction,
                time: DateTime.now(),
              ),
            );
          } catch (e) {
            debugPrint('감지 기록을 저장하지 못했습니다: $e');
          }

          if (!mounted) return;

          setState(() {
            _recentLogs.insert(0, {
              'sound': event.sound,
              'direction': event.direction,
              'time': DateTime.now(),
            });
            if (_recentLogs.length > 20) _recentLogs.removeLast();
          });
        };
        // 백그라운드에서도 감지가 이어지도록 마이크보다 먼저 서비스를 올린다
        final serviceStarted = await ForegroundService.start();
        try {
          await _manager.startMonitoring();
        } catch (_) {
          // 일부만 시작된 구독(이어폰·활동)과 마이크가 남지 않도록 정리한다.
          // 정리 실패가 원래 예외를 가리지 않도록 여기서 삼킨다.
          try {
            await _manager.stopMonitoring();
          } catch (e) {
            debugPrint('감지 시작 실패 후 정리 중 오류: $e');
          }
          await ForegroundService.stop();
          rethrow;
        }
        _earphoneConnected = _manager.earphoneConnected;
        // 앱이 떠 있는 동안의 감지는 동작하지만 백그라운드 유지는 보장되지 않는다
        if (!serviceStarted && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('백그라운드에서는 감지가 유지되지 않을 수 있어요.')),
          );
        }
      }
      setState(() => _isListening = !_isListening);
      await WidgetService.publishListening(_isListening);
    } finally {
      _isToggling = false;
    }
  }

  @override
  void dispose() {
    WidgetService.onToggleRequest = null;
    WidgetService.dispose();
    _motionSubscription?.cancel();
    _sensitivitySubscription?.cancel();
    _indoorOutdoorSubscription?.cancel();
    _earphoneSubscription?.cancel();
    // State.dispose는 async가 아니므로 비동기 정리는 fire-and-forget으로 넘긴다.
    unawaited(_manager.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F5FA),
      body: SafeArea(
        child: switch (_currentIndex) {
          0 => _buildHomeTab(),
          1 => const StatsPage(),
          _ => const SettingsPage(),
        },
      ),
      bottomNavigationBar: buildBottomNav(),
    );
  }

  Widget _buildHomeTab() {
    return RefreshIndicator(
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
              ListenableBuilder(
                listenable: _settings,
                builder: (context, _) => Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (_settings.demoMode)
                      buildDemoBadge()
                    else ...[
                      buildOutdoorBadge(),
                      buildMotionBadge(),
                    ],
                    buildSensitivityBadge(),
                    if (_settings.earphoneOnly && !_earphoneConnected) buildEarphoneBadge(),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            const Text('감지 항목', style: sectionTitle),
            const SizedBox(height: 12),
            ListenableBuilder(
              listenable: _settings,
              builder: (context, _) => AlertGrid(
                isListening: _isListening,
                isWaiting: _micWaiting,
              ),
            ),
            const SizedBox(height: 20),
            const Text('최근 감지', style: sectionTitle),
            const SizedBox(height: 12),
            RecentList(logs: _recentLogs),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  static const sectionTitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w700,
    color: Color(0xFF1A1A2E),
  );

  Widget buildSensitivityBadge() {
    final (icon, color) = switch (_sensitivityLevel) {
      SensitivityLevel.high => (
        Icons.warning_amber_rounded,
        const Color(0xFFFF3B30),
      ),
      SensitivityLevel.elevated => (Icons.cell_tower, const Color(0xFFFF9500)),
      SensitivityLevel.normal => (Icons.graphic_eq, const Color(0xFF8A8FA8)),
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
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget buildEarphoneBadge() {
    const color = Color(0xFFFF9500);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.headset_off_outlined, size: 16, color: color),
          SizedBox(width: 8),
          Text('이어폰 미연결', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }

  /// 데모 모드에서는 걷기·실내외 조건을 쓰지 않으므로 두 배지 대신 이 배지 하나만 보여준다.
  Widget buildDemoBadge() {
    const color = Color(0xFF8E5BF6);
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
          const Icon(Icons.slideshow_outlined, size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            _micWaiting ? '데모 모드 · 마이크 대기' : '데모 모드 · 마이크 활성',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }

  Widget buildOutdoorBadge() {
    final (icon, label, color) = switch (_indoorState) {
      IndoorOutdoorState.outdoor  => (Icons.wb_sunny_outlined, '실외', const Color(0xFF34C759)),
      IndoorOutdoorState.checking => (Icons.gps_fixed, '위치 확인 중...', const Color(0xFF5B9CF6)),
      IndoorOutdoorState.indoor   => (Icons.home_outlined, '실내 · 마이크 대기', const Color(0xFF8A8FA8)),
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
            label,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }

  Widget buildMotionBadge() {
    final micActive = _motionState == MotionState.moving &&
        _indoorState == IndoorOutdoorState.outdoor;
    final (icon, label, color) = switch (_motionState) {
      MotionState.moving when micActive => (
        Icons.directions_walk,
        '이동 중 · 마이크 활성',
        const Color(0xFF34C759),
      ),
      MotionState.moving => (
        Icons.directions_walk,
        '이동 중 · 마이크 대기',
        const Color(0xFF8A8FA8),
      ),
      MotionState.still => (
        Icons.pause_circle_outline,
        '정지 · 마이크 대기',
        const Color(0xFFFF9500),
      ),
      MotionState.unknown => (
        Icons.sensors,
        '활동 감지 중...',
        const Color(0xFF8A8FA8),
      ),
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
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget buildHeader() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
        selectedLabelStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
        unselectedLabelStyle: const TextStyle(fontSize: 11),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: '홈',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bar_chart_outlined),
            activeIcon: Icon(Icons.bar_chart),
            label: '통계',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings),
            label: '설정',
          ),
        ],
      ),
    );
  }
}
