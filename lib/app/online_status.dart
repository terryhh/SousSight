// A simple connectivity read for the dispatcher and Coach Lite. Read at each
// send; never cached. On web this is `navigator.onLine`, which can say
// "online" behind a captive portal but reliably says "offline" when the
// device has no network. Elsewhere it reports online and lets the request
// fail on its own.
export 'online_status_stub.dart'
    if (dart.library.js_interop) 'online_status_web.dart'
    show deviceOnline;
