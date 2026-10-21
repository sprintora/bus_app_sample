import 'dart:convert';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

class QueuedEvent {
  final int id;
  final String kind;
  final DateTime time;
  final Map<String, dynamic> data;
  QueuedEvent(this.id, this.kind, this.time, this.data);
}

/// Local storage on the phone: the outgoing queue, the card->student list,
/// de-duplication keys and small settings.
class AppDb {
  AppDb._();
  static final AppDb instance = AppDb._();

  Future<Database>? _opening;
  final Set<String> _seenMem = {};

  Future<Database> get _db => _opening ??= _open();

  Future<Database> _open() async {
    final path = join(await getDatabasesPath(), 'bus_driver.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, v) async {
        await db.execute('CREATE TABLE kv(k TEXT PRIMARY KEY, v TEXT)');
        await db.execute('CREATE TABLE events('
            'id INTEGER PRIMARY KEY AUTOINCREMENT, '
            'kind TEXT NOT NULL, ts INTEGER NOT NULL, payload TEXT NOT NULL)');
        await db.execute(
            'CREATE TABLE cards(uid TEXT PRIMARY KEY, name TEXT NOT NULL)');
        await db.execute(
            'CREATE TABLE seen(k TEXT PRIMARY KEY, ts INTEGER NOT NULL)');
      },
    );
  }

  // ---- settings -----------------------------------------------------------
  Future<String?> getKv(String k) async {
    final db = await _db;
    final rows = await db.query('kv', where: 'k = ?', whereArgs: [k]);
    return rows.isEmpty ? null : rows.first['v'] as String?;
  }

  Future<void> setKv(String k, String? v) async {
    final db = await _db;
    if (v == null) {
      await db.delete('kv', where: 'k = ?', whereArgs: [k]);
    } else {
      await db.insert('kv', {'k': k, 'v': v},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  // ---- outgoing queue -----------------------------------------------------
  Future<int> addEvent(
      String kind, DateTime time, Map<String, dynamic> payload) async {
    final db = await _db;
    return db.insert('events', {
      'kind': kind,
      'ts': time.millisecondsSinceEpoch,
      'payload': jsonEncode(payload),
    });
  }

  Future<List<QueuedEvent>> oldestEvents(int limit) async {
    final db = await _db;
    final rows = await db.query('events', orderBy: 'id ASC', limit: limit);
    return rows
        .map((r) => QueuedEvent(
              r['id'] as int,
              r['kind'] as String,
              DateTime.fromMillisecondsSinceEpoch(r['ts'] as int),
              jsonDecode(r['payload'] as String) as Map<String, dynamic>,
            ))
        .toList();
  }

  Future<void> deleteEvents(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _db;
    final marks = List.filled(ids.length, '?').join(',');
    await db.delete('events', where: 'id IN ($marks)', whereArgs: ids);
  }

  Future<int> pendingCount() async {
    final db = await _db;
    return Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM events')) ??
        0;
  }

  // ---- students (card -> name) -------------------------------------------
  Future<void> replaceCards(Map<String, String> cards) async {
    final db = await _db;
    final batch = db.batch();
    batch.delete('cards');
    cards.forEach((uid, name) {
      batch.insert('cards', {'uid': uid.toUpperCase(), 'name': name},
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
    await batch.commit(noResult: true);
  }

  Future<String?> cardName(String uid) async {
    final db = await _db;
    final rows = await db.query('cards', where: 'uid = ?', whereArgs: [uid]);
    return rows.isEmpty ? null : rows.first['name'] as String?;
  }

  Future<int> cardCount() async {
    final db = await _db;
    return Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM cards')) ??
        0;
  }

  // ---- duplicate protection for BLE re-sends ------------------------------
  /// Returns true the first time a key is seen, false for repeats.
  Future<bool> markSeen(String key) async {
    if (!_seenMem.add(key)) return false;
    final db = await _db;
    final rows = await db.query('seen', where: 'k = ?', whereArgs: [key]);
    if (rows.isNotEmpty) return false;
    await db.insert('seen',
        {'k': key, 'ts': DateTime.now().millisecondsSinceEpoch});
    // keep the table small: forget keys older than 2 days
    await db.delete('seen',
        where: 'ts < ?',
        whereArgs: [
          DateTime.now()
              .subtract(const Duration(days: 2))
              .millisecondsSinceEpoch
        ]);
    return true;
  }
}
