import 'contract.dart';
import 'method_channel_hybrid_inference.dart';
import 'web/web_hybrid_inference.dart';

HybridInference Function()? _backendFactory;
HybridInference? _instance;

/// Override for tests and alternative backends. Pass null to restore the
/// platform default.
void registerHybridInferenceBackend(HybridInference Function()? factory) {
  _backendFactory = factory;
  _instance = null;
}

/// The process-wide backend. Configure it once with [HybridInference.configure].
///
/// Web: the JS-interop backend over the Firebase AI Logic JS SDK (SS-062).
/// Android and iOS: [MethodChannelHybridInference]. A backend registered with
/// [registerHybridInferenceBackend] takes precedence (tests, fakes).
HybridInference defaultHybridInference() =>
    _instance ??= (_backendFactory ?? _platformDefault)();

HybridInference _platformDefault() =>
    webHybridInference() ?? MethodChannelHybridInference();
