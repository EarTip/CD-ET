import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../services/log_repository.dart';

enum StatsPeriod { week, month }

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
    Color(0xFFFF6B6B),
    Color(0xFF5B9CF6),
    Color(0xFFFFA94D),
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
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(20),
        children: [
          SegmentedButton<StatsPeriod>(
            segments: const [
              ButtonSegment(value: StatsPeriod.week, label: Text('주간')),
              ButtonSegment(value: StatsPeriod.month, label: Text('월간')),
            ],
            selected: {_period},
            onSelectionChanged: (s) => _onPeriodChanged(s.first),
          ),
          const SizedBox(height: 24),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(top: 60),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_hasError)
            const Padding(
              padding: EdgeInsets.only(top: 60),
              child: Center(
                child: Text(
                  '통계를 불러오지 못했어요. 다시 시도해주세요.',
                  style: TextStyle(color: Colors.grey),
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
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
            )
          else ...[
            Text(
              '${_period == StatsPeriod.week ? "이번 주" : "이번 달"} 총 $_total회 감지',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            if (_peakHour >= 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '가장 많이 감지된 시간대: $_peakHour시대',
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
            const SizedBox(height: 24),
            SizedBox(
              height: 200,
              child: PieChart(
                PieChartData(
                  sectionsSpace: 2,
                  centerSpaceRadius: 40,
                  sections: _buildSections(),
                ),
              ),
            ),
            const SizedBox(height: 20),
            ..._buildLegend(),
          ],
        ],
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
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: _colors[i % _colors.length],
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(e.key)),
            Text('${e.value}회', style: const TextStyle(color: Colors.grey)),
          ],
        ),
      );
    });
  }
}
