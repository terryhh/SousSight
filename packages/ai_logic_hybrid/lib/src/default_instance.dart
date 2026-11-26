import 'contract.dart';
import 'method_channel_hybrid_inference.dart';
import 'web/web_hybrid_inference.dart';

HybridInference Function()? _backendFactory;
HybridInference? _instance;

/// Overrides the backend [defaultHybridInference] returns, e.g. a
/// [FakeHybridInference] in Rehearsal mode. Call before first use.
void registerHybridInferenceBackend(HybridInference Function() factory) {
  _backendFactory = factory;
  _instance = null;
}

/// The process-wide backend. Configure it once with [HybridInference.configure].
///
/// Web: the JS-interop backend (SS-062). Android and iOS:
/// [MethodChannelHybridInference]. A registered override wins over both. A
/// platform with no working bridge reports `platform: 'none'` and
/// `bridge_unavailable`; it never throws.
HybridInference defaultHybridInference() => _instance ??=
    _backendFactory?.call() ??
    webHybridInference() ??
    MethodChannelHybridInference();
