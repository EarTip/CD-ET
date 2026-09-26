import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/detection_log.dart';

class LogRepository {
  static final instance = LogRepository._();
  LogRepository._();
  Database? _db;

  Future<Database> get db async => _db ??= await openDatabase(
    join(await getDatabasesPath(), 'eartip.db'),
    version: 1,
    onCreate: (d, _) => d.execute('''
      CREATE TABLE logs(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sound TEXT, direction TEXT, time INTEGER)'''),
  );

  Future<int> insert(DetectionLog log) async =>
      (await db).insert('logs', log.toMap());

  Future<List<DetectionLog>> recent({int limit = 20}) async {
    final rows = await (await db).query(
      'logs',
      orderBy: 'time DESC',
      limit: limit,
    );
    return rows.map(DetectionLog.fromMap).toList();
  }

  Future<List<DetectionLog>> since(DateTime from) async {
    final rows = await (await db).query(
      'logs',
      where: 'time >= ?',
      whereArgs: [from.millisecondsSinceEpoch],
      orderBy: 'time DESC',
    );
    return rows.map(DetectionLog.fromMap).toList();
  }

  Future<Map<String, int>> countByClass(DateTime from) async {
    final logs = await since(from);
    final Map<String, int> counts = {};
    for (final log in logs) {
      counts[log.sound.name] = (counts[log.sound.name] ?? 0) + 1;
    }
    return counts;
  }

  Future<int> peakHour(DateTime from) async {
    final logs = await since(from);
    if (logs.isEmpty) return -1;
    final Map<int, int> hourCounts = {};
    for (final log in logs) {
      hourCounts[log.time.hour] = (hourCounts[log.time.hour] ?? 0) + 1;
    }
    return hourCounts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }
}
