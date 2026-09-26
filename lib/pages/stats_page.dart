import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../services/log_repository.dart';
import '../services/settings_service.dart';
import '../services/sound_detector.dart';

enum StatsPeriod { week, month }

const _kBlue = Color(0xFF5B9CF6);
const _kTextDark = Color(0xFF1A1A2E);
const _kTextGrey = Color(0xFF8A8FA8);

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  StatsPeriod _period = StatsPeriod.week;
  Map<String, int> _classCounts = {};
  int _peakHour = -1;
  int _total = 0;
  bool _loading = true;
  bool _hasError = false;
  int _loadToken = 0;

  static const _colors = [
    Color(0xFF5B9CF6),
    Color(0xFF3D6FD1),
    Color(0xFF8AC4F7),
    Color(0xFF63E6BE),
    Color(0xFFB197FC),
  ];

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final myToken = ++_loadToken;
    setState(() {
      _loading = true;
      _hasError = false;
    });
    final from = _period == StatsPeriod.week ? _weekStart() : _monthStart();

    try {
      final counts = await LogRepository.instance.countByClass(from);
      final peak = await LogRepository.instance.peakHour(from);
      if (mounted && myToken == _loadToken) {
        setState(() {
          _classCounts = counts;
          _peakHour = peak;
          _total = counts.values.fold(0, (a, b) => a + b);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted && myToken == _loadToken) {
        setState(() {
          _loading = false;
          _hasError = true;
        });
      }
    }
  }

  DateTime _weekStart() {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    return DateTime(monday.year, monday.month, monday.day);
  }

  DateTime _monthStart() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, 1);
  }

  void _onPeriodChanged(StatsPeriod period) {
    if (period == _period) return;
    setState(() => _period = period);
    _loadStats();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _loadStats,
      color: _kBlue,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: [
          const SizedBox(height: 24),
          _buildPeriodToggle(),
          const SizedBox(height: 24),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: 60),
              child: Center(
                child: CircularProgressIndicator(color: _kBlue),
              ),
            )
          else if (_hasError)
            const Padding(
              padding: EdgeInsets.only(top: 60),
              child: Center(
                child: Text(
                  '통계를 불러오지 못했어요. 다시 시도해주세요.',
                  style: TextStyle(fontSize: 13, color: _kTextGrey),
                ),
              ),
            )
          else if (_total == 0)
            Padding(
              padding: const EdgeInsets.only(top: 60),
              child: Center(
                child: Text(
                  _period == StatsPeriod.week
                      ? '이번 주 감지 기록이 없어요'
                      : '이번 달 감지 기록이 없어요',
                  style: const TextStyle(fontSize: 13, color: _kTextGrey),
                ),
              ),
            )
          else ...[
            Text(
              '${_period == StatsPeriod.week ? "이번 주" : "이번 달"} 총 $_total회 감지',
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: _kTextDark,
              ),
            ),
            if (_peakHour >= 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '가장 많이 감지된 시간대: $_peakHour시대',
                  style: const TextStyle(fontSize: 13, color: _kTextGrey),
                ),
              ),
            const SizedBox(height: 24),
            _buildChartCard(),
            const SizedBox(height: 20),
            ..._buildLegend(),
          ],
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildPeriodToggle() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(4),
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
      child: Row(
        children: [
          Expanded(child: _periodPill('주간', StatsPeriod.week)),
          const SizedBox(width: 4),
          Expanded(child: _periodPill('월간', StatsPeriod.month)),
        ],
      ),
    );
  }

  Widget _periodPill(String label, StatsPeriod period) {
    final selected = _period == period;
    return GestureDetector(
      onTap: () => _onPeriodChanged(period),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? _kBlue.withValues(alpha: 0.1) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: selected
              ? Border.all(color: _kBlue.withValues(alpha: 0.3))
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? _kBlue : _kTextGrey,
          ),
        ),
      ),
    );
  }

  Widget _buildChartCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: SizedBox(
        height: 200,
        child: PieChart(
          PieChartData(
            sectionsSpace: 2,
            centerSpaceRadius: 40,
            sections: _buildSections(),
          ),
        ),
      ),
    );
  }

  List<PieChartSectionData> _buildSections() {
    final entries = _classCounts.entries.toList();
    return List.generate(entries.length, (i) {
      final e = entries[i];
      final pct = (e.value / _total * 100);
      return PieChartSectionData(
        value: e.value.toDouble(),
        title: '${pct.toStringAsFixed(0)}%',
        color: _colors[i % _colors.length],
        radius: 70,
        titleStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      );
    });
  }

  List<Widget> _buildLegend() {
    final entries = _classCounts.entries.toList();
    return List.generate(entries.length, (i) {
      final e = entries[i];
      final sound = DetectedSound.values.byName(e.key);
      final color = _colors[i % _colors.length];
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
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(_iconFor(sound), color: color, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                sound.label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: _kTextDark,
                ),
              ),
            ),
            Text(
              '${e.value}회',
              style: const TextStyle(fontSize: 13, color: _kTextGrey),
            ),
          ],
        ),
      );
    });
  }

  IconData _iconFor(DetectedSound sound) => switch (sound) {
        DetectedSound.horn => Icons.car_crash_outlined,
        DetectedSound.siren => Icons.emergency_outlined,
        DetectedSound.brake => Icons.directions_car_outlined,
        DetectedSound.none => Icons.volume_off_outlined,
      };
}
