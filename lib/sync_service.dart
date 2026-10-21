import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'db.dart';

/// Sends the queued events to the server in batches. An event is deleted from
/// the phone only after the server answers with a 2xx status.
class SyncService extends ChangeNotifier {
  SyncService._();
  static final SyncService instance = SyncService._();

  final AppDb _db = AppDb.instance;

  int pending = 0;
  DateTime? lastOk;
  String? lastError;
  bool syncing = false;
  Timer? _timer;

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 15), (_) => syncNow());
    refreshPending();
    syncNow();
  }

  Future<void> refreshPending() async {
    pending = await _db.pendingCount();
    notifyListeners();
  }

  Future<String?> _baseUrl() async {
    var url = (await _db.getKv('server_url'))?.trim() ?? '';
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url.isEmpty ? null : url;
  }

  Future<Map<String, String>> _headers() async => {
        'content-type': 'application/json',
        'x-device-id': (await _db.getKv('device_id')) ?? 'BUS-001',
        'x-device-key': (await _db.getKv('api_key')) ?? '',
      };

  Future<void> syncNow() async {
    if (syncing) return;
    final base = await _baseUrl();
    if (base == null) {
      await refreshPending();
      return;
    }
    syncing = true;
    notifyListeners();
    try {
      final headers = await _headers();
      final deviceId = headers['x-device-id'];
      while (true) {
        final batch = await _db.oldestEvents(100);
        if (batch.isEmpty) break;
        final body = jsonEncode({
          'deviceId': deviceId,
          'sentAt': DateTime.now().toUtc().toIso8601String(),
          'events': batch.map((e) {
            final tripId = e.data['tripId'] ?? 'NOTRIP';
            return {
              'clientId': '$tripId:${e.id}',
              'kind': e.kind,
              'time': e.time.toUtc().toIso8601String(),
              ...e.data,
            };
          }).toList(),
        });
        final res = await http
            .post(Uri.parse('$base/api/device/events'),
                headers: headers, body: body)
            .timeout(const Duration(seconds: 20));
        if (res.statusCode >= 200 && res.statusCode < 300) {
          await _db.deleteEvents(batch.map((e) => e.id).toList());
          lastOk = DateTime.now();
          lastError = null;
        } else {
          lastError = 'Server replied ${res.statusCode}';
          break;
        }
      }
    } catch (e) {
      lastError = 'No connection to server';
    } finally {
      syncing = false;
      await refreshPending();
    }
  }

  /// Downloads the card -> student list so names can be shown offline.
  /// Expected reply: {"cards":[{"uid":"04A1B2C3","name":"Nimal"}, ...]}
  Future<String> downloadRoster() async {
    final base = await _baseUrl();
    if (base == null) return 'Enter the server address first.';
    try {
      final res = await http
          .get(Uri.parse('$base/api/device/roster'), headers: await _headers())
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return 'Server replied ${res.statusCode}';
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final cards = <String, String>{};
      for (final c in (json['cards'] as List)) {
        cards[(c['uid'] as String).toUpperCase()] = c['name'] as String;
      }
      await _db.replaceCards(cards);
      return 'Student list updated: ${cards.length} cards.';
    } catch (e) {
      return 'Could not download the list: $e';
    }
  }
}
