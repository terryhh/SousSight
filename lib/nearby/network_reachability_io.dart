import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Lists the device's network interfaces (injectable for tests).
typedef InterfaceLister = Future<List<NetworkInterface>> Function();

Future<List<NetworkInterface>> _osInterfaces() =>
    NetworkInterface.list(includeLoopback: false, includeLinkLocal: false);

/// True when some interface has a routable (not loopback, not link-local)
/// address. An error reads as true: unknown, so the request decides.
Future<bool> networkReachable() => reachableVia(_osInterfaces);

@visibleForTesting
Future<bool> reachableVia(InterfaceLister list) async {
  try {
    final interfaces = await list();
    return interfaces.any(
      (i) => i.addresses.any((a) => !a.isLoopback && !a.isLinkLocal),
    );
  } catch (_) {
    return true;
  }
}
