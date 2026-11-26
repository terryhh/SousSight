import 'package:flutter/foundation.dart';

import 'browser_live_media.dart';
import 'live_types.dart';
import 'native_live_media_factory_stub.dart'
    if (dart.library.io) 'native_live_media_plugins.dart';

/// The platform's camera, microphone and speaker for the Live coach and the
/// local watch: browser media on web, the camera/record plugins on Android and
/// iOS. Each call returns a new, idle instance.
LiveMedia createLiveMedia() =>
    kIsWeb ? createBrowserLiveMedia() : createNativeLiveMedia();
