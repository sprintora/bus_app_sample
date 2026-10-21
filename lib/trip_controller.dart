import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import 'db.dart';
import 'gps_service.dart';
import 'sync_service.dart';

enum BoardStatus { boarding, alighting }

extension BoardStatusX on BoardStatus {
  String get code => this == BoardStatus.boarding ? 'BOARDING' : 'ALIGHTING';
}

class ScanView {
  final String uid;
  final String? name;
  final BoardStatus status;
  final String outcome; // OK, DUPLICATE, NOT_ABOARD, UNKNOWN_CARD, NO_TRIP
  final DateTime time;
  ScanView(this.uid, this.name, this.status, this.outcome, this.time);
}

/// Owns the trip, the BOARDING/ALIGHTING status and the list of students who
/// are on board. Every action is written to the local queue first.
class TripController extends ChangeNotifier {
  TripController._();
  static final TripController instance = TripController._();

  final AppDb _db = AppDb.instance;
  final GpsService gps = GpsService.instance;

  String? tripId;
  BoardStatus status = BoardStatus.boarding;
  Set<String> onboard = {};
  final List<ScanView> recent = []; // newest first
  String? warning;

  bool get active => tripId != null;
  int get onboardCount => onboard.length;

  Future<void> restore() async {
    tripId = await _db.getKv('trip_id');
    status = (await _db.getKv('status')) == 'ALIGHTING'
        ? BoardStatus.alighting
        : BoardStatus.boarding;
    final raw = await _db.getKv('onboard');
    if (raw != null) {
      onboard = (jsonDecode(raw) as List).cast<String>().toSet();
    }
    notifyListeners();
    if (active) {
      // The app was restarted during a trip: resume GPS recording.
      final err = await _startGps();
      if (err != null) gps.error = err;
    }
  }

  Future<void> _save() async {
    await _db.setKv('trip_id', tripId);
    await _db.setKv('status', status.code);
    await _db.setKv('onboard', jsonEncode(onboard.toList()));
  }

  Future<String?> _startGps() async {
    final seconds =
        int.tryParse(await _db.getKv('gps_interval') ?? '') ?? 10;
    return gps.start(
      recordEvery: Duration(seconds: seconds.clamp(3, 120).toInt()),
      onRecord: _recordGps,
    );
  }

  void _recordGps(Position p) {
    final id = tripId;
    if (id == null) return;
    _db.addEvent('gps', DateTime.now(), {
      'tripId': id,
      'lat': p.latitude,
      'lng': p.longitude,
      'accuracy': p.accuracy,
      'speed': p.speed,
      'heading': p.heading,
    });
    SyncService.instance.refreshPending();
  }

  Future<String?> startTrip() async {
    final deviceId = (await _db.getKv('device_id')) ?? 'BUS-001';
    final id =
        '$deviceId-${DateTime.now().millisecondsSinceEpoch.toRadixString(36).toUpperCase()}';

    final err = await _startGps();
    if (err != null) return err;

    tripId = id;
    status = BoardStatus.boarding;
    onboard = {};
    recent.clear();
    warning = null;
    final now = DateTime.now();
    await _db.addEvent('trip', now, {'tripId': id, 'action': 'start'});
    await _db.addEvent(
        'status', now, {'tripId': id, 'status': status.code});
    await _save();
    notifyListeners();
    SyncService.instance.refreshPending();
    return null;
  }

  Future<void> endTrip() async {
    final id = tripId;
    if (id == null) return;
    await gps.stop();
    await _db.addEvent('trip', DateTime.now(), {
      'tripId': id,
      'action': 'end',
      'stillOnboard': onboard.toList(),
    });
    tripId = null;
    onboard = {};
    warning = null;
    await _save();
    notifyListeners();
    unawaited(SyncService.instance.syncNow());
  }

  Future<void> setStatus(BoardStatus s) async {
    final id = tripId;
    if (id == null || s == status) return;
    status = s;
    await _db.addEvent('status', DateTime.now(), {
      'tripId': id,
      'status': s.code,
    });
    await _save();
    HapticFeedback.mediumImpact();
    notifyListeners();
    SyncService.instance.refreshPending();
  }

  /// Called for every card tap that arrives from the ESP32 unit.
  Future<void> handleTap(String uid, DateTime tapTime) async {
    final name = await _db.cardName(uid);
    final rosterSize = await _db.cardCount();

    if (!active) {
      warning = 'Card tapped but no trip is running. Start the trip first.';
      _remember(ScanView(uid, name, status, 'NO_TRIP', tapTime));
      _feedback(false);
      notifyListeners();
      return;
    }

    String outcome = 'OK';
    if (status == BoardStatus.boarding) {
      if (!onboard.add(uid)) outcome = 'DUPLICATE';
    } else {
      if (!onboard.remove(uid)) outcome = 'NOT_ABOARD';
    }
    if (outcome == 'OK' && rosterSize > 0 && name == null) {
      outcome = 'UNKNOWN_CARD';
    }

    final fix = gps.freshFix(const Duration(seconds: 30));
    await _db.addEvent('scan', tapTime, {
      'tripId': tripId,
      'uid': uid,
      'status': status.code,
      'outcome': outcome,
      if (name != null) 'name': name,
      if (fix != null) 'lat': fix.latitude,
      if (fix != null) 'lng': fix.longitude,
      if (fix != null) 'accuracy': fix.accuracy,
    });
    await _save();

    warning = null;
    _remember(ScanView(uid, name, status, outcome, tapTime));
    _feedback(outcome == 'OK');
    notifyListeners();
    SyncService.instance.refreshPending();
  }

  void _remember(ScanView v) {
    recent.insert(0, v);
    if (recent.length > 30) recent.removeLast();
  }

  Future<void> _feedback(bool ok) async {
    HapticFeedback.heavyImpact();
    SystemSound.play(SystemSoundType.click);
    if (!ok) {
      await Future<void>.delayed(const Duration(milliseconds: 180));
      HapticFeedback.heavyImpact();
    }
  }
}
