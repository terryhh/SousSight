// Web backend (card SS-062, DESIGN.md §3 Web, §4). A thin dart:js_interop layer over
// globalThis.aiLogicHybrid, defined by assets/ai_logic_hybrid.js. All SDK logic, limits,
// timeouts and error mapping live in that script and are covered by
// test/hybrid/web_bridge_test.cjs. This file only moves values across the boundary.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import '../contract.dart';

const _assetKey = 'packages/ai_logic_hybrid/assets/ai_logic_hybrid.js';

@JS('aiLogicHybrid')
external _Bridge? get _bridge;

extension type _Bridge(JSObject _) implements JSObject {
  external JSPromise<JSAny?> configure(JSObject config);
  external JSPromise<JSAny?> capabilities();
  external JSPromise<JSAny?> availability(JSObject args);
  external JSPromise<JSAny?> prepare(JSObject args, JSFunction onProgress);
  external JSPromise<JSAny?> generate(JSObject request);
  external JSPromise<JSAny?> cancel(JSString requestId);
  external JSPromise<_Envelope> settle(JSPromise<JSAny?> promise);
}

/// `{ok: true, value}` or `{ok: false, code, message}`; see `settle` in the script.
extension type _Envelope(JSObject _) implements JSObject {
  external bool get ok;
  external JSAny? get value;
  external String? get code;
  external String? get message;
}

/// Plugin registration. Injects the bridge script at app start so that a later
/// [WebHybridInference.prepare] can start the model download synchronously, inside the
/// cook's tap.
class AiLogicHybridWeb {
  static void registerWith(Registrar registrar) {
    ensureLoaded();
  }

  static Future<bool>? _loading;

  /// Completes with whether `globalThis.aiLogicHybrid` is present. Never throws.
  static Future<bool> ensureLoaded() => _loading ??= _inject();

  static Future<bool> _inject() {
    if (_bridge != null) return Future<bool>.value(true);
    final completer = Completer<bool>();
    void done(bool _) {
      if (!completer.isCompleted) completer.complete(_bridge != null);
    }

    try {
      final script = web.HTMLScriptElement()
        ..src = ui_web.assetManager.getAssetUrl(_assetKey)
        ..async = true;
      script.addEventListener('load', ((web.Event _) => done(true)).toJS);
      script.addEventListener('error', ((web.Event _) => done(false)).toJS);
      (web.document.head ?? web.document.documentElement)?.append(script);
    } catch (_) {
      done(false);
    }
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => _bridge != null,
    );
  }
}

/// The web [HybridInference]: Firebase AI Logic JS SDK hybrid inference with Chrome's
/// built-in model. Rules from DESIGN.md §4: never throws for a missing bridge from
/// [capabilities] / [availability]; [generate] throws [HybridException].
class WebHybridInference implements HybridInference {
  WebHybridInference._();

  static final WebHybridInference instance = WebHybridInference._();

  /// Extra time the Dart side waits beyond `task.timeout` before giving up on the
  /// script, which enforces the timeout itself.
  static const _backstop = Duration(seconds: 5);

  Future<_Bridge?> _ready() async {
    await AiLogicHybridWeb.ensureLoaded();
    return _bridge;
  }

  Future<JSAny?> _call(_Bridge bridge, JSPromise<JSAny?> promise) async {
    final envelope = await bridge.settle(promise).toDart;
    if (envelope.ok) return envelope.value;
    throw HybridException(
      HybridErrorCode.values.asNameMap()[envelope.code] ??
          HybridErrorCode.failed,
      envelope.message ?? 'web bridge error',
    );
  }

  @override
  Future<void> configure(HybridConfig config) async {
    final bridge = await _ready();
    if (bridge == null) return; // reported by capabilities/availability
    final js = JSObject()
      ..['cloudModel'] = config.cloudModel.toJS
      ..['androidModel'] = config.androidModel.name.toJS
      ..['languages'] = [for (final l in config.languages) l.toJS].toJS;
    await _call(bridge, bridge.configure(js));
  }

  @override
  Future<HybridCapabilities> capabilities() async {
    final bridge = await _ready();
    if (bridge == null) return const HybridCapabilities.none();
    try {
      final value = await _call(bridge, bridge.capabilities());
      return HybridCapabilities.fromMap(_map(value));
    } catch (_) {
      return const HybridCapabilities.none();
    }
  }

  @override
  Future<HybridAvailability> availability({required bool withImage}) async {
    const missing = HybridAvailability(
      status: OnDeviceStatus.unavailable,
      reason: 'bridge_unavailable',
    );
    final bridge = await _ready();
    if (bridge == null) return missing;
    try {
      final value = await _call(
        bridge,
        bridge.availability(_imageArg(withImage)),
      );
      return HybridAvailability.fromMap(_map(value));
    } catch (_) {
      return missing;
    }
  }

  @override
  Stream<double?> prepare({required bool withImage}) {
    // Work starts now, before anyone listens, so events that arrive before the first
    // listener are held and replayed to it rather than dropped by the broadcast stream.
    final held = <void Function()>[];
    late final StreamController<double?> controller;
    controller = StreamController<double?>.broadcast(
      onListen: () {
        final replay = List.of(held);
        held.clear();
        for (final event in replay) {
          event();
        }
      },
    );
    void emit(void Function() event) {
      if (controller.hasListener) {
        event();
      } else {
        held.add(event);
      }
    }

    void fail(Object error, [StackTrace? stack]) => emit(() {
      controller
        ..addError(error, stack)
        ..close();
    });

    void start(_Bridge? bridge) {
      if (bridge == null) {
        fail(
          const HybridException(
            HybridErrorCode.unavailable,
            'bridge_unavailable',
          ),
        );
        return;
      }
      // Called synchronously when the script is already loaded (the normal case: it is
      // injected at startup), so the download starts inside the caller's gesture.
      final promise = bridge.prepare(
        _imageArg(withImage),
        ((JSNumber? fraction) {
          final value = fraction?.toDartDouble;
          emit(() {
            if (!controller.isClosed) controller.add(value);
          });
        }).toJS,
      );
      _call(bridge, promise).then((_) => emit(controller.close), onError: fail);
    }

    final bridge = _bridge;
    if (bridge != null) {
      start(bridge);
    } else {
      // The gesture may have expired by the time the script loads; Chrome then refuses
      // the download and the stream errors with `unavailable`.
      AiLogicHybridWeb.ensureLoaded().then((_) => start(_bridge));
    }
    return controller.stream;
  }

  @override
  Future<HybridResult> generate(HybridRequest request) async {
    final bridge = await _ready();
    if (bridge == null) {
      throw const HybridException(
        HybridErrorCode.unavailable,
        'bridge_unavailable',
      );
    }
    final value = await _call(bridge, bridge.generate(_request(request)))
        .timeout(
          request.task.timeout + _backstop,
          onTimeout: () {
            bridge.cancel(request.requestId.toJS);
            throw const HybridException(
              HybridErrorCode.timeout,
              'web bridge did not answer',
            );
          },
        );
    return HybridResult.fromMap(_map(value));
  }

  @override
  Future<void> cancel(String requestId) async {
    final bridge = await _ready();
    if (bridge == null) return;
    await _call(bridge, bridge.cancel(requestId.toJS));
  }
}

/// The web backend, or null where the bridge script is not present. See
/// `web_hybrid_inference.dart` for the platform-neutral entry point.
HybridInference? webHybridInference() => WebHybridInference.instance;

JSObject _imageArg(bool withImage) =>
    JSObject()..['withImage'] = withImage.toJS;

JSObject _request(HybridRequest r) {
  final task = r.task;
  final js = JSObject()
    ..['requestId'] = r.requestId.toJS
    ..['mode'] = r.mode.name.toJS
    ..['feature'] = task.feature.toJS
    ..['maxOutputTokens'] = task.maxOutputTokens.toJS
    ..['timeoutMs'] = task.timeout.inMilliseconds.toJS
    ..['parts'] = [
      for (final part in task.parts)
        switch (part) {
          HybridText(:final text) =>
            JSObject()
              ..['type'] = 'text'.toJS
              ..['text'] = text.toJS,
          HybridInlineData(:final bytes, :final mimeType) =>
            JSObject()
              ..['type'] = 'inlineData'.toJS
              ..['mimeType'] = mimeType.toJS
              ..['bytes'] = bytes.toJS,
        },
    ].toJS;
  final instruction = task.systemInstruction;
  if (instruction != null) js['systemInstruction'] = instruction.toJS;
  final schema = task.jsonSchema;
  if (schema != null) js['jsonSchema'] = schema.jsify();
  return js;
}

/// `dartify` yields doubles for JS numbers on some compilers; the contract maps expect
/// ints for counts and limits.
Map<Object?, Object?> _map(JSAny? value) {
  final dart = _normalize(value.dartify());
  if (dart is Map<Object?, Object?>) return dart;
  throw const HybridException(
    HybridErrorCode.failed,
    'web bridge returned no object',
  );
}

Object? _normalize(Object? v) => switch (v) {
  final Map<Object?, Object?> m => {
    for (final e in m.entries) e.key: _normalize(e.value),
  },
  final List<Object?> l => [for (final x in l) _normalize(x)],
  final double d when d.isFinite && d == d.truncateToDouble() => d.toInt(),
  _ => v,
};
