import 'nearby_client.dart';

/// Thrown when the location is denied, unavailable, or unsupported.
class LocationUnavailable implements Exception {
  const LocationUnavailable();
}

/// Non-web hosts and tests: no geolocation. The cook types a city or ZIP.
Future<NearbyCoordinates> locateOnce() =>
    Future.error(const LocationUnavailable());
