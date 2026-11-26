// Moments to re-read connectivity for the offline step queue (SS-072). The
// answer itself always comes from `deviceOnline` (lib/app/online_status.dart),
// the same source the dispatcher, Coach Lite and research use; these events
// only say when to look again. On web they are the window's `online` and
// `offline` events. Elsewhere there are none, and failed saves retry on a
// timer instead.
export 'offline_ops_connectivity_stub.dart'
    if (dart.library.js_interop) 'offline_ops_connectivity_web.dart'
    show connectivityChanges;
