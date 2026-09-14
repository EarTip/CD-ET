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
}
