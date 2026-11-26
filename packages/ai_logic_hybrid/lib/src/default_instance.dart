import 'contract.dart';
import 'method_channel_hybrid_inference.dart';

HybridInference Function()? _backendFactory;
HybridInference? _instance;

/// Hook for a backend that does not use the method channel.
///
/// The web backend (SS-062) calls this from `AiLogicHybridWeb.registerWith`,
/// which Flutter runs before `main`, so [defaultHybridInference] returns the
/// JS-interop backend on web and the method channel everywhere else.
void registerHybridInferenceBackend(HybridInference Function() factory) {
  _backendFactory = factory;
  _instance = null;
}

/// The process-wide backend. Configure it once with [HybridInference.configure].
///
/// Android and iOS: [MethodChannelHybridInference]. Web: the backend
/// registered with [registerHybridInferenceBackend].
///
/// HOOK for SS-062 (#182): once `src/web/web_hybrid_inference.dart` is on the
/// trunk, import it here and make the factory
/// `webHybridInference() ?? MethodChannelHybridInference()`; the
/// registration hook can then go. Until then, web without a registered
/// backend gets the method channel, which reports `platform: 'none'` and
/// `bridge_unavailable` (never throws).
HybridInference defaultHybridInference() =>
    _instance ??= (_backendFactory ?? MethodChannelHybridInference.new)();
