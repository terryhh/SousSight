// The one Nearby client for real builds (Codex #221): the `nearby` cloud
// route is checked before the cook is asked for a location (via [allowed])
// and again at the send boundary, and every send is recorded in the session
// ledger by the wrapped client.

import 'nearby_client.dart';

/// Shown when the build does not approve the `nearby` route.
const kNearbyOffMessage =
    "Nearby search is off in this build, so nothing was sent. Check a local "
    'food bank or 211 for help nearby.';

/// Whether [client] may search now. Unguarded clients (rehearsal, tests)
/// always may.
bool nearbyAllowed(NearbyClient client) =>
    client is! GuardedNearbyClient || client.allowed();

class GuardedNearbyClient implements NearbyClient {
  GuardedNearbyClient({required this.inner, required this.allowed});

  final NearbyClient inner;

  /// Read live: before asking for a location and immediately before a send.
  final bool Function() allowed;

  @override
  Future<NearbyResult> find(NearbyQuery query) {
    if (!allowed()) {
      return Future.error(
        const NearbyException(NearbyFailure.unavailable, kNearbyOffMessage),
      );
    }
    return inner.find(query);
  }
}
