import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'db.dart';

/// Bluetooth Low Energy link to the ESP32 + RC522 unit.
///
/// Packets from the unit (notifications, max 20 bytes):
///   tap    : [1, bootLo, bootHi, seqLo, seqHi, age0..age3 (ms, LE), uidLen, uid...]
///   status : [2, readerOk(0/1), unsentCount, bootLo, bootHi]
/// Packet to the unit (write):
///   ack    : [1, bootLo, bootHi, seqLo, seqHi]
class RfidLink extends ChangeNotifier {
  RfidLink._();
  static final RfidLink instance = RfidLink._();

  static final Guid serviceUuid = Guid('7a5f0001-3b1c-4f6e-9d2a-5c1e8b7a0001');
  static final Guid txUuid = Guid('7a5f0002-3b1c-4f6e-9d2a-5c1e8b7a0001');
  static final Guid rxUuid = Guid('7a5f0003-3b1c-4f6e-9d2a-5c1e8b7a0001');

  final AppDb _db = AppDb.instance;

  /// Set by main(): called for every new card tap. Must finish (without
  /// throwing) before the tap is acknowledged to the unit.
  Future<void> Function(String uid, DateTime tapTime)? onTap;

  bool connected = false;
  bool? readerOk;
  int? unitUnsent;
  String? deviceLabel;
  DateTime? lastHeartbeat;
  String? error;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rx;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _txSub;
  Timer? _livenessTimer;

  bool get alive =>
      lastHeartbeat != null &&
      DateTime.now().difference(lastHeartbeat!) < const Duration(seconds: 20);

  /// Connects to the RFID unit chosen in Settings and keeps reconnecting.
  Future<void> connectSaved() async {
    final id = await _db.getKv('rfid_id');
    await _disconnectCurrent();
    if (id == null || id.isEmpty) {
      deviceLabel = null;
      notifyListeners();
      return;
    }
    deviceLabel = (await _db.getKv('rfid_name')) ?? id;
    error = null;
    notifyListeners();

    try {
      if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
        await FlutterBluePlus.turnOn();
      }
    } catch (_) {
      error = 'Please turn Bluetooth on.';
      notifyListeners();
    }

    final dev = BluetoothDevice.fromId(id);
    _device = dev;
    _connSub = dev.connectionState.listen((s) {
      if (s == BluetoothConnectionState.connected) {
        _setupLink(dev);
      } else {
        _teardownLink();
      }
    });
    _livenessTimer ??=
        Timer.periodic(const Duration(seconds: 5), (_) => notifyListeners());

    try {
      // autoConnect: Android reconnects by itself whenever the unit is in range.
      await dev.connect(autoConnect: true, mtu: null);
    } catch (e) {
      error = 'Bluetooth: $e';
      notifyListeners();
    }
  }

  Future<void> selectDevice(ScanResult r) async {
    final name = r.advertisementData.advName.isNotEmpty
        ? r.advertisementData.advName
        : r.device.platformName;
    await _db.setKv('rfid_id', r.device.remoteId.str);
    await _db.setKv('rfid_name', name.isEmpty ? r.device.remoteId.str : name);
    await connectSaved();
  }

  Future<void> _disconnectCurrent() async {
    await _connSub?.cancel();
    _connSub = null;
    _teardownLink();
    final d = _device;
    _device = null;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {}
    }
  }

  void _teardownLink() {
    _txSub?.cancel();
    _txSub = null;
    _rx = null;
    connected = false;
    readerOk = null;
    unitUnsent = null;
    notifyListeners();
  }

  Future<void> _setupLink(BluetoothDevice dev) async {
    try {
      final services = await dev.discoverServices();
      BluetoothCharacteristic? tx;
      BluetoothCharacteristic? rx;
      for (final s in services) {
        if (s.uuid != serviceUuid) continue;
        for (final c in s.characteristics) {
          if (c.uuid == txUuid) tx = c;
          if (c.uuid == rxUuid) rx = c;
        }
      }
      if (tx == null || rx == null) {
        error = 'This Bluetooth device is not a Bus RFID unit.';
        notifyListeners();
        return;
      }
      _rx = rx;
      await _txSub?.cancel();
      _txSub = tx.onValueReceived.listen(_onData);
      await tx.setNotifyValue(true);
      connected = true;
      error = null;
      lastHeartbeat = DateTime.now();
      notifyListeners();
    } catch (e) {
      error = 'Bluetooth link failed: $e';
      notifyListeners();
    }
  }

  Future<void> _onData(List<int> d) async {
    if (d.isEmpty) return;

    if (d[0] == 2 && d.length >= 5) {
      readerOk = d[1] == 1;
      unitUnsent = d[2];
      lastHeartbeat = DateTime.now();
      notifyListeners();
      return;
    }

    if (d[0] == 1 && d.length >= 10) {
      final boot = d[1] | (d[2] << 8);
      final seq = d[3] | (d[4] << 8);
      final age = d[5] | (d[6] << 8) | (d[7] << 16) | (d[8] << 24);
      final len = d[9];
      if (len == 0 || d.length < 10 + len) return;
      final uid = d
          .sublist(10, 10 + len)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join()
          .toUpperCase();

      try {
        final isNew = await _db.markSeen('$boot-$seq');
        if (isNew) {
          final tapTime =
              DateTime.now().subtract(Duration(milliseconds: age));
          await onTap?.call(uid, tapTime);
        }
        await _ack(boot, seq);
      } catch (_) {
        // Not acknowledged: the unit will send this tap again.
      }
      lastHeartbeat = DateTime.now();
    }
  }

  Future<void> _ack(int boot, int seq) async {
    final rx = _rx;
    if (rx == null) return;
    try {
      await rx.write([
        1,
        boot & 0xFF,
        (boot >> 8) & 0xFF,
        seq & 0xFF,
        (seq >> 8) & 0xFF,
      ]);
    } catch (_) {}
  }
}
