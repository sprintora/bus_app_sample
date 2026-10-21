import 'dart:async';

import 'package:flutter/material.dart';

import 'gps_service.dart';
import 'home_page.dart';
import 'rfid_link.dart';
import 'sync_service.dart';
import 'trip_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final gps = GpsService.instance;
  final trip = TripController.instance;
  final rfid = RfidLink.instance;

  await gps.init();
  await trip.restore();

  // Every card tap from the ESP32 goes to the trip controller.
  rfid.onTap = trip.handleTap;
  unawaited(rfid.connectSaved());
  SyncService.instance.start();

  runApp(const BusDriverApp());
}

class BusDriverApp extends StatelessWidget {
  const BusDriverApp({super.key});

  @override
  Widget build(BuildContext context) {
    final trip = TripController.instance;
    return MaterialApp(
      title: 'Bus Driver',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: ListenableBuilder(
        listenable: trip,
        builder: (context, _) => PopScope(
          // During a trip the Back button hides the app instead of closing
          // it, so GPS recording and the RFID link keep running.
          canPop: !trip.active,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) GpsService.instance.moveToBack();
          },
          child: const HomePage(),
        ),
      ),
    );
  }
}
