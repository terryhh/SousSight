import 'dart:async';

import 'package:flutter/foundation.dart';

import '../live/live_types.dart';

/// Who holds the camera and microphone. DESIGN.md §6 SS-067.
enum CaptureMode {
  /// Nothing captured.
  off,

  /// Camera only, frames stay on this device (local watch).
  localCamera,

  /// Camera and microphone, streamed to the Live coach.
  liveAv,
}

/// Proof of one acquisition. Frames and later calls are honoured only while
/// the lease is current; any later transition invalidates it.
class CaptureLease {
  const CaptureLease._(this.generation, this.mode);
  final int generation;
  final CaptureMode mode;
}

/// The single owner of the shared [LiveMedia]. Every transition releases the
/// previous capture first, and an acquisition that settles after a newer
/// transition (a late permission grant, a slow `getUserMedia`) never becomes
/// current and never publishes frames.
class CaptureOwner extends ChangeNotifier {
  CaptureOwner(this.media);

  final LiveMedia media;
  CaptureMode _mode = CaptureMode.off;
  CaptureMode? _pending;
  int _generation = 0;
  bool _disposed = false;

  /// What is held right now.
  CaptureMode get mode => _mode;

  /// What is being acquired, if anything (e.g. while a permission prompt is
  /// open).
  CaptureMode? get pending => _pending;

  bool isCurrent(CaptureLease lease) =>
      lease.generation == _generation && _mode == lease.mode;

  /// Camera-only capture for the local watch. Returns null if a newer
  /// transition superseded this one before it settled. Throws if the camera
  /// could not be started (for example, permission denied).
  Future<CaptureLease?> acquireLocalCamera() =>
      _acquire(CaptureMode.localCamera, media.startCameraOnly);

  /// Camera and microphone, started by this owner.
  Future<CaptureLease?> acquireLiveAv() =>
      _acquire(CaptureMode.liveAv, media.start);

  /// For today's `LiveCookingController`, which starts the shared [LiveMedia]
  /// itself in `connect`: release any local capture first, then record that
  /// Live holds the camera and microphone. Call before `live.start`.
  Future<void> handOffToLive() async {
    final generation = ++_generation;
    final hadCapture = _mode != CaptureMode.off || _pending != null;
    _mode = CaptureMode.off;
    _pending = CaptureMode.liveAv;
    _notify();
    if (hadCapture) await media.stop();
    if (generation != _generation) return;
    _pending = null;
    _mode = CaptureMode.liveAv;
    _notify();
  }

  /// Records that Live released capture on its own (stop, idle, error),
  /// without stopping anything a newer owner may hold.
  void liveReleased() {
    if (_mode != CaptureMode.liveAv || _pending != null) return;
    ++_generation;
    _mode = CaptureMode.off;
    _notify();
  }

  /// Stops whatever is held and invalidates every lease and pending start.
  Future<void> release() async {
    ++_generation;
    final hadCapture = _mode != CaptureMode.off || _pending != null;
    _mode = CaptureMode.off;
    _pending = null;
    _notify();
    if (hadCapture) await media.stop();
  }

  /// Frames for [lease], dropped as soon as the lease stops being current.
  Stream<CapturedFrame> framesFor(CaptureLease lease) =>
      media.timedFrames.where((_) => isCurrent(lease));

  Future<CaptureLease?> _acquire(
    CaptureMode target,
    Future<void> Function() start,
  ) async {
    final generation = ++_generation;
    final previous = _mode;
    final wasPending = _pending != null;
    _mode = CaptureMode.off;
    _pending = target;
    _notify();
    // Release first: the previous holder's capture (and any start still
    // waiting on a permission prompt) is stopped before the new one begins.
    if (previous != CaptureMode.off || wasPending) await media.stop();
    if (generation != _generation) return null;
    try {
      await start();
    } catch (_) {
      // A superseded start's failure is not the caller's problem any more.
      if (generation != _generation) return null;
      _pending = null;
      _mode = CaptureMode.off;
      _notify();
      await media.stop();
      rethrow;
    }
    // A newer transition already stopped the media after this start began;
    // do not claim it and do not stop the newer holder's capture.
    if (generation != _generation) return null;
    _pending = null;
    _mode = target;
    _notify();
    return CaptureLease._(generation, target);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
