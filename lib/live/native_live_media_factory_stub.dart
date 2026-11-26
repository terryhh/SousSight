import 'live_types.dart';

/// Web builds never construct native capture; see live_media_factory.dart.
LiveMedia createNativeLiveMedia() =>
    throw UnsupportedError('Native camera capture is not available on web.');
