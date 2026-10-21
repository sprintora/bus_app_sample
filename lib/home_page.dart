import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'gps_service.dart';
import 'rfid_link.dart';
import 'settings_page.dart';
import 'sync_service.dart';
import 'trip_controller.dart';

const Color _boardingColor = Color(0xFF2E7D32);
const Color _alightingColor = Color(0xFFE65100);

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final trip = TripController.instance;
    final rfid = RfidLink.instance;
    final gps = GpsService.instance;
    final sync = SyncService.instance;

    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge([trip, rfid, gps, sync]),
          builder: (context, _) {
            final landscape =
                MediaQuery.of(context).orientation == Orientation.landscape;
            return Column(
              children: [
                _topStrip(context, trip, rfid, gps, sync),
                if (gps.hasGms == false) _gmsWarning(context),
                Expanded(
                  child: Stack(
                    children: [
                      // The split screen: two big halves.
                      Flex(
                        direction: landscape ? Axis.horizontal : Axis.vertical,
                        children: [
                          _half(context, trip, BoardStatus.boarding,
                              'BOARDING', Icons.login, _boardingColor),
                          _half(context, trip, BoardStatus.alighting,
                              'ALIGHTING', Icons.logout, _alightingColor),
                        ],
                      ),
                      if (!trip.active) _noTripOverlay(context, trip),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ---- small status strip --------------------------------------------------
  Widget _topStrip(BuildContext context, TripController trip, RfidLink rfid,
      GpsService gps, SyncService sync) {
    // RFID unit
    late String rfidText;
    late IconData rfidIcon;
    late Color rfidColor;
    if (rfid.deviceLabel == null) {
      rfidText = 'RFID: select unit';
      rfidIcon = Icons.bluetooth_searching;
      rfidColor = Colors.orange;
    } else if (!rfid.connected) {
      rfidText = 'RFID: connecting...';
      rfidIcon = Icons.bluetooth_searching;
      rfidColor = Colors.orange;
    } else if (!rfid.alive) {
      rfidText = 'RFID: no signal';
      rfidIcon = Icons.bluetooth_disabled;
      rfidColor = Colors.red;
    } else if (rfid.readerOk == false) {
      rfidText = 'RFID reader fault';
      rfidIcon = Icons.error_outline;
      rfidColor = Colors.red;
    } else {
      rfidText = 'RFID ready';
      rfidIcon = Icons.bluetooth_connected;
      rfidColor = Colors.green.shade700;
    }

    // GPS
    late String gpsText;
    late Color gpsColor;
    if (!gps.running) {
      gpsText = 'GPS off';
      gpsColor = Colors.grey;
    } else if (gps.latest == null) {
      gpsText = 'GPS waiting...';
      gpsColor = Colors.orange;
    } else {
      final acc = gps.latest!.accuracy;
      gpsText = 'GPS ±${acc.toStringAsFixed(0)} m';
      gpsColor = acc <= 50 ? Colors.green.shade700 : Colors.orange;
    }

    // Queue / server
    final syncColor = sync.lastError != null
        ? Colors.red
        : (sync.pending == 0 ? Colors.green.shade700 : Colors.orange);
    final syncText = sync.lastError != null
        ? 'Unsent ${sync.pending} (${sync.lastError})'
        : 'Unsent: ${sync.pending}';

    void openSettings() => Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SettingsPage()));

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _chip(rfidIcon, rfidText, rfidColor, openSettings),
                _chip(Icons.gps_fixed, gpsText, gpsColor, null),
                _chip(Icons.cloud_upload_outlined, syncText, syncColor,
                    () => SyncService.instance.syncNow()),
              ],
            ),
          ),
          if (trip.active)
            TextButton(
              onPressed: () => _confirmEnd(context, trip),
              child: const Text('End trip'),
            ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: openSettings,
          ),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String text, Color color, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Color.lerp(Colors.white, color, 0.14),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Text(text,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _gmsWarning(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'Warning: Google Play Services not found. Using the phone\'s '
        'built-in GPS; the first fix may take longer.',
        style: TextStyle(fontSize: 12, color: scheme.onTertiaryContainer),
      ),
    );
  }

  // ---- the two halves ------------------------------------------------------
  Widget _half(BuildContext context, TripController trip, BoardStatus s,
      String title, IconData icon, Color color) {
    final selected = trip.status == s;
    final bg = selected ? color : Color.lerp(Colors.white, color, 0.14)!;
    final fg = selected ? Colors.white : color;

    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(24),
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: (!trip.active || selected) ? null : () => trip.setStatus(s),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 72, color: fg),
                      Text(title,
                          style: TextStyle(
                              fontSize: 40,
                              fontWeight: FontWeight.w800,
                              color: fg)),
                      const SizedBox(height: 4),
                      Text(
                        selected
                            ? 'ACTIVE - students tap their cards'
                            : 'Tap here to switch',
                        style: TextStyle(fontSize: 16, color: fg),
                      ),
                      const SizedBox(height: 8),
                      Text('On board: ${trip.onboardCount}',
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: fg)),
                      if (selected && trip.recent.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        _lastScan(trip.recent.first),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _lastScan(ScanView v) {
    const labels = {
      'OK': 'Accepted',
      'DUPLICATE': 'Already on board',
      'NOT_ABOARD': 'Was not on board',
      'UNKNOWN_CARD': 'Unknown card',
      'NO_TRIP': 'Ignored (no trip)',
    };
    final ok = v.outcome == 'OK';
    return Container(
      width: 290,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(v.name ?? v.uid,
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: Colors.black87)),
          if (v.name != null)
            Text(v.uid,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 4),
          Text(labels[v.outcome] ?? v.outcome,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: ok ? Colors.green.shade800 : Colors.red.shade700)),
          Text(DateFormat('hh:mm:ss a').format(v.time),
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ],
      ),
    );
  }

  // ---- no trip -------------------------------------------------------------
  Widget _noTripOverlay(BuildContext context, TripController trip) {
    return Positioned.fill(
      child: Container(
        color: Colors.black54,
        alignment: Alignment.center,
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('No trip running',
                    style:
                        TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                if (trip.warning != null) ...[
                  const SizedBox(height: 8),
                  Text(trip.warning!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.red.shade700)),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => _startTrip(context, trip),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start trip'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 28, vertical: 16),
                    textStyle: const TextStyle(fontSize: 18),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _startTrip(BuildContext context, TripController trip) async {
    final err = await trip.startTrip();
    if (err != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
    }
  }

  Future<void> _confirmEnd(BuildContext context, TripController trip) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End this trip?'),
        content: Text(trip.onboardCount > 0
            ? '${trip.onboardCount} student(s) are still marked as on board.'
            : 'All students are off the bus.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('End trip')),
        ],
      ),
    );
    if (ok == true) await trip.endTrip();
  }
}
