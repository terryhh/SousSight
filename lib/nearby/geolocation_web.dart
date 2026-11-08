import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'nearby_client.dart';

/// Thrown when the location is denied, unavailable, or unsupported.
class LocationUnavailable implements Exception {
  const LocationUnavailable();
}

/// Asks the browser for one coarse position after the cook taps the button.
/// Nothing is watched, cached, or stored.
Future<NearbyCoordinates> locateOnce() {
  final completer = Completer<NearbyCoordinates>();
  void fail() {
    if (!completer.isCompleted) {
      completer.completeError(const LocationUnavailable());
    }
  }

  try {
    web.window.navigator.geolocation.getCurrentPosition(
      ((web.GeolocationPosition position) {
        if (completer.isCompleted) return;
        final coordinates = NearbyCoordinates(
          position.coords.latitude,
          position.coords.longitude,
        );
        coordinates.isValid ? completer.complete(coordinates) : fail();
      }).toJS,
      ((JSAny? _) => fail()).toJS,
      web.PositionOptions(
        enableHighAccuracy: false,
        timeout: 10000,
        maximumAge: 0,
      ),
    );
  } catch (_) {
    fail();
  }
  return completer.future.timeout(
    const Duration(seconds: 15),
    onTimeout: () => throw const LocationUnavailable(),
  );
}
