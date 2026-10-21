import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'db.dart';
import 'rfid_link.dart';
import 'sync_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final AppDb _db = AppDb.instance;
  final _url = TextEditingController();
  final _deviceId = TextEditingController();
  final _apiKey = TextEditingController();
  final _interval = TextEditingController();

  String? _msg;
  bool _scanning = false;
  int _cards = 0;
  List<ScanResult> _found = [];
  StreamSubscription<List<ScanResult>>? _scanSub;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    FlutterBluePlus.stopScan();
    _url.dispose();
    _deviceId.dispose();
    _apiKey.dispose();
    _interval.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    _url.text = (await _db.getKv('server_url')) ?? '';
    _deviceId.text = (await _db.getKv('device_id')) ?? 'BUS-001';
    _apiKey.text = (await _db.getKv('api_key')) ?? '';
    _interval.text = (await _db.getKv('gps_interval')) ?? '10';
    _cards = await _db.cardCount();
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    await _db.setKv('server_url', _url.text.trim());
    await _db.setKv('device_id', _deviceId.text.trim());
    await _db.setKv('api_key', _apiKey.text.trim());
    final secs = int.tryParse(_interval.text.trim()) ?? 10;
    await _db.setKv('gps_interval', secs.clamp(3, 120).toString());
    setState(() => _msg = 'Saved. The GPS interval applies from the next trip.');
    SyncService.instance.syncNow();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _found = [];
      _msg = null;
    });
    try {
      await _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((r) {
        if (mounted) setState(() => _found = r);
      });
      await FlutterBluePlus.startScan(
        withServices: [RfidLink.serviceUuid],
        timeout: const Duration(seconds: 8),
      );
      await FlutterBluePlus.isScanning.where((s) => !s).first;
    } catch (e) {
      _msg = 'Search failed: $e';
    }
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _pick(ScanResult r) async {
    await RfidLink.instance.selectDevice(r);
    if (mounted) setState(() => _msg = 'RFID unit selected. Connecting...');
  }

  Future<void> _roster() async {
    await _save();
    final m = await SyncService.instance.downloadRoster();
    _cards = await _db.cardCount();
    if (mounted) setState(() => _msg = m);
  }

  @override
  Widget build(BuildContext context) {
    final rfid = RfidLink.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('RFID unit (ESP32 + RC522)',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          ListenableBuilder(
            listenable: rfid,
            builder: (context, _) => Text(
              rfid.deviceLabel == null
                  ? 'No unit selected.'
                  : 'Selected: ${rfid.deviceLabel}  '
                      '(${rfid.connected ? 'connected' : 'not connected'})'
                      '${rfid.error != null ? '\n${rfid.error}' : ''}',
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: _scanning ? null : _scan,
            icon: const Icon(Icons.bluetooth_searching),
            label: Text(_scanning ? 'Searching...' : 'Search for RFID units'),
          ),
          for (final r in _found)
            ListTile(
              leading: const Icon(Icons.nfc),
              title: Text(r.advertisementData.advName.isNotEmpty
                  ? r.advertisementData.advName
                  : r.device.remoteId.str),
              subtitle: Text('Signal ${r.rssi} dBm'),
              trailing: const Text('Select'),
              onTap: () => _pick(r),
            ),
          const Divider(height: 32),
          Text('Server', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Server address',
              hintText: 'https://your-app.vercel.app',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _deviceId,
            decoration: const InputDecoration(
              labelText: 'Bus / device ID',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKey,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Secret API key',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _interval,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Save GPS position every (seconds, 3-120)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(onPressed: _save, child: const Text('Save')),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: _roster,
                  child: const Text('Download student list'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('Student cards stored on this phone: $_cards'),
          if (_msg != null) ...[
            const SizedBox(height: 12),
            Text(_msg!),
          ],
        ],
      ),
    );
  }
}
