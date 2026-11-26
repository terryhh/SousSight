// Native connectivity for the Nearby gate (Codex #224). On web the gate's
// `isOnline` is `navigator.onLine`; on Android and iOS `deviceOnline()` has
// no signal, so this asks the OS for a network interface with a routable
// address. In airplane mode or with Wi-Fi and cellular off there is none.
// Best effort: it cannot see a captive portal, and an error reads as
// "reachable" so the request decides.
export 'network_reachability_stub.dart'
    if (dart.library.io) 'network_reachability_io.dart'
    show networkReachable;
