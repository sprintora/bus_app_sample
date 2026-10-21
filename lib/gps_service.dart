import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

/// Phone GPS. Keeps running in the background (foreground service) while a
/// trip is active and records one point every [recordEvery].
class GpsService extends ChangeNotifier {
  GpsService._();
  static final GpsService instance = GpsService._();

  static const MethodChannel _env = MethodChannel('bus_driver/env');

  bool running = false;

  /// null = unknown, true = Google Play Services found, false = missing.
  bool? hasGms;

  Position? latest;
  DateTime? latestAt;
  String? error;

  StreamSubscription<Position>? _sub;
  Timer? _timer;

  Future<void> init() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      hasGms = await _env.invokeMethod<bool>('hasGooglePlayServices');
    } catch (_) {}
  }

  Future<void> moveToBack() async {
    try {
      await _env.invokeMethod<void>('moveToBack');
    } catch (_) {}
  }

  /// Latest fix if it is not older than [maxAge].
  Position? freshFix(Duration maxAge) {
    final p = latest;
    final at = latestAt;
    if (p == null || at == null) return null;
    return DateTime.now().difference(at) <= maxAge ? p : null;
  }

  Future<String?> start({
    required Duration recordEvery,
    required void Function(Position p) onRecord,
  }) async {
    if (running) return null;
    error = null;

    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'Location (GPS) is turned off. Please turn it on.';
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied) {
      return 'Location permission was denied.';
    }
    if (perm == LocationPermission.deniedForever) {
      return 'Location permission is permanently denied. Enable it in '
          'Settings > Apps > Bus Driver > Permissions.';
    }

    final LocationSettings settings =
        defaultTargetPlatform == TargetPlatform.android
            ? AndroidSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: 0,
                forceLocationManager: hasGms == false,
                intervalDuration: const Duration(seconds: 3),
                foregroundNotificationConfig:
                    const ForegroundNotificationConfig(
                  notificationTitle: 'Bus trip in progress',
                  notificationText: 'Recording route and card taps',
                  notificationChannelName: 'Bus trip',
                  enableWakeLock: true,
                  setOngoing: true,
                ),
              )
            : const LocationSettings(accuracy: LocationAccuracy.high);

    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      (p) {
        latest = p;
        latestAt = DateTime.now();
        notifyListeners();
      },
      onError: (Object e) {
        error = 'GPS error: $e';
        notifyListeners();
      },
    );

    _timer = Timer.periodic(recordEvery, (_) {
      final p = freshFix(recordEvery * 3 + const Duration(seconds: 10));
      if (p != null) onRecord(p);
    });

    running = true;
    notifyListeners();
    return null;
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _sub?.cancel();
    _sub = null;
    running = false;
    notifyListeners();
  }
}
