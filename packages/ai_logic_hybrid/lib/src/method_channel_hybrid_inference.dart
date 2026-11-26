// Native (Android, iOS) backend: the channel protocol in DESIGN.md §4.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'contract.dart';

/// Talks to the Kotlin (SS-063) and Swift (SS-064) plugins.
///
/// Never throws for a missing bridge: with no native plugin registered,
/// [capabilities] is [HybridCapabilities.none], [availability] is
/// `unavailable` / `bridge_unavailable`, [configure] and [cancel] are no-ops,
/// and [generate] / [prepare] fail with [HybridErrorCode.unavailable] so the
/// dispatcher can decide what to do next.
class MethodChannelHybridInference implements HybridInference {
  MethodChannelHybridInference({
    MethodChannel? methodChannel,
    String prepareChannelName = prepareChannel,
    BinaryMessenger? binaryMessenger,
    this.timeoutGrace = const Duration(seconds: 2),
  }) : _method = methodChannel ?? const MethodChannel(methodChannelName),
       _prepareName = prepareChannelName,
       _messenger = binaryMessenger;

  static const methodChannelName = 'dev.soussight/ai_logic_hybrid';
  static const prepareChannel = 'dev.soussight/ai_logic_hybrid/prepare';

  /// Reason reported when no native plugin answered.
  static const bridgeUnavailable = 'bridge_unavailable';

  /// How long past `task.timeout` the Dart side waits before giving up on a
  /// native call that did not honour its own timeout.
  final Duration timeoutGrace;

  final MethodChannel _method;
  final String _prepareName;
  final BinaryMessenger? _messenger;
  _Prepare? _activePrepare;

  BinaryMessenger get _binaryMessenger =>
      _messenger ?? ServicesBinding.instance.defaultBinaryMessenger;

  @override
  Future<void> configure(HybridConfig config) async {
    try {
      await _method.invokeMethod<void>('configure', config.toMap());
    } on MissingPluginException {
      // No bridge: capabilities() will say so.
    } on PlatformException catch (e) {
      throw hybridExceptionFromPlatform(e);
    }
  }

  @override
  Future<HybridCapabilities> capabilities() async {
    try {
      final map = await _method.invokeMapMethod<Object?, Object?>(
        'capabilities',
      );
      if (map == null) return const HybridCapabilities.none();
      return HybridCapabilities.fromMap(map);
    } on MissingPluginException {
      return const HybridCapabilities.none();
    } on PlatformException catch (e) {
      if (e.code == HybridErrorCode.unavailable.name) {
        return const HybridCapabilities.none();
      }
      throw hybridExceptionFromPlatform(e);
    }
  }

  @override
  Future<HybridAvailability> availability({required bool withImage}) async {
    try {
      final map = await _method.invokeMapMethod<Object?, Object?>(
        'availability',
        {'withImage': withImage},
      );
      if (map == null) return _bridgeUnavailable;
      return HybridAvailability.fromMap(map);
    } on MissingPluginException {
      return _bridgeUnavailable;
    } on PlatformException catch (e) {
      if (e.code == HybridErrorCode.unavailable.name) {
        return HybridAvailability(
          status: OnDeviceStatus.unavailable,
          reason: e.message ?? bridgeUnavailable,
        );
      }
      throw hybridExceptionFromPlatform(e);
    }
  }

  /// Starts the native `listen` now, not when the caller subscribes (§4).
  /// One prepare runs at a time: a call for the same modality while one is
  /// running returns the running stream; a different modality errors `busy`.
  @override
  Stream<double?> prepare({required bool withImage}) {
    final active = _activePrepare;
    if (active != null && !active.isClosed) {
      if (active.withImage == withImage) return active.stream;
      return Stream<double?>.error(
        const HybridException(
          HybridErrorCode.busy,
          'Another prepare is running',
        ),
      );
    }
    final prepare = _Prepare(withImage);
    _activePrepare = prepare;
    _startPrepare(prepare);
    return prepare.stream;
  }

  void _startPrepare(_Prepare prepare) {
    const codec = StandardMethodCodec();
    void release() => _binaryMessenger.setMessageHandler(_prepareName, null);

    _binaryMessenger.setMessageHandler(_prepareName, (ByteData? reply) async {
      if (reply == null) {
        release();
        prepare.close();
        return null;
      }
      try {
        final event = codec.decodeEnvelope(reply);
        final fraction = event is Map ? event['fraction'] : null;
        prepare.add(fraction is num ? fraction.toDouble() : null);
      } on PlatformException catch (e) {
        release();
        prepare.fail(hybridExceptionFromPlatform(e));
      }
      return null;
    });
    MethodChannel(_prepareName, codec, _messenger)
        .invokeMethod<void>('listen', {'withImage': prepare.withImage})
        .catchError((Object error) {
          release();
          prepare.fail(
            error is PlatformException
                ? hybridExceptionFromPlatform(error)
                : const HybridException(
                    HybridErrorCode.unavailable,
                    bridgeUnavailable,
                  ),
          );
        });
  }

  @override
  Future<HybridResult> generate(HybridRequest request) async {
    final call = _method.invokeMapMethod<Object?, Object?>(
      'generate',
      request.toMap(),
    );
    final Map<Object?, Object?>? map;
    try {
      map = await call.timeout(
        request.task.timeout + timeoutGrace,
        onTimeout: () {
          unawaited(cancel(request.requestId));
          throw const HybridException(
            HybridErrorCode.timeout,
            'Native call timed out',
          );
        },
      );
    } on MissingPluginException {
      throw const HybridException(
        HybridErrorCode.unavailable,
        bridgeUnavailable,
      );
    } on PlatformException catch (e) {
      throw hybridExceptionFromPlatform(e);
    }
    if (map == null) {
      throw const HybridException(HybridErrorCode.failed, 'Empty result');
    }
    final HybridResult result;
    try {
      result = HybridResult.fromMap(map);
    } catch (e) {
      // Includes a missing or unknown `source`: never inferred (§4).
      throw HybridException(HybridErrorCode.failed, 'Malformed result: $e');
    }
    if (result.requestId != request.requestId) {
      throw const HybridException(HybridErrorCode.failed, 'Stale result');
    }
    return result;
  }

  @override
  Future<void> cancel(String requestId) async {
    try {
      await _method.invokeMethod<void>('cancel', {'requestId': requestId});
    } on MissingPluginException {
      // Nothing to cancel.
    } on PlatformException {
      // Best effort; the backend completes the call with `cancelled`.
    }
  }

  static const _bridgeUnavailable = HybridAvailability(
    status: OnDeviceStatus.unavailable,
    reason: bridgeUnavailable,
  );
}

/// One running prepare. Native work starts before anyone listens, so each
/// listener is replayed the latest fraction and the terminal error or done:
/// a late listener must never mistake an earlier failure for readiness.
class _Prepare {
  _Prepare(this.withImage);
  final bool withImage;
  final List<MultiStreamController<double?>> _listeners = [];
  bool _hasFraction = false;
  double? _fraction;
  HybridException? _error;
  bool isClosed = false;

  late final Stream<double?> stream = Stream<double?>.multi((c) {
    if (_hasFraction) c.add(_fraction);
    if (isClosed) {
      if (_error != null) c.addError(_error!);
      c.close();
      return;
    }
    _listeners.add(c);
    c.onCancel = () => _listeners.remove(c);
  }, isBroadcast: true);

  void add(double? fraction) {
    if (isClosed) return;
    _hasFraction = true;
    _fraction = fraction;
    for (final c in [..._listeners]) {
      c.add(fraction);
    }
  }

  void fail(HybridException error) {
    if (isClosed) return;
    _error = error;
    for (final c in [..._listeners]) {
      c.addError(error);
    }
    close();
  }

  void close() {
    if (isClosed) return;
    isClosed = true;
    for (final c in [..._listeners]) {
      c.close();
    }
    _listeners.clear();
  }
}

/// Maps a channel error to the contract: `code` is a [HybridErrorCode] name;
/// anything else is [HybridErrorCode.failed].
@visibleForTesting
HybridException hybridExceptionFromPlatform(PlatformException e) {
  final code =
      HybridErrorCode.values.asNameMap()[e.code] ?? HybridErrorCode.failed;
  return HybridException(code, e.message ?? e.code);
}
