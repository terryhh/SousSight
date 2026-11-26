// Platform-neutral entry point to the web backend. Import this, not
// ai_logic_hybrid_web.dart, from code that also compiles for the VM or native.
//
//   final inference = webHybridInference() ?? <native or fake backend>;
export 'web_hybrid_inference_stub.dart'
    if (dart.library.js_interop) 'ai_logic_hybrid_web.dart'
    show webHybridInference;
