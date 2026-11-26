import 'package:flutter/material.dart';

import 'app/hybrid_runtime.dart';
import 'app/rehearsal_runtime.dart';
import 'app/services_scope.dart';
import 'config/firebase_remote_config_source.dart';
import 'config/remote_policy.dart';
import 'data/firebase_services.dart';
import 'learner/cooking_app.dart';
import 'pantry/recipe_catalog.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SousSightBootstrap());
}

class SousSightBootstrap extends StatefulWidget {
  const SousSightBootstrap({super.key});
  @override
  State<SousSightBootstrap> createState() => _SousSightBootstrapState();
}

class _SousSightBootstrapState extends State<SousSightBootstrap> {
  late Future<(AppServices, HybridRuntime?)> _services = _load();

  /// Rehearsal (practice mode) is fully simulated: its hybrid runtime answers
  /// from a scripted fake, labelled "Practice mode (pretend answers)" on every
  /// surface, and nothing leaves the browser. Real builds initialize Firebase
  /// and App Check first, then configure the hybrid backend once (its web
  /// bridge uses the Firebase app created here).
  Future<(AppServices, HybridRuntime?)> _load() async {
    if (kFakeBackend) {
      return (await fakeServices(), RehearsalHybridRuntime.create());
    }
    final services = await firebaseServices();
    // Remote Config can only tighten routing; it waits at most 2 s and falls
    // back to the in-app defaults (SS-076).
    final remote = await RemotePolicy.load(
      FirebaseRemoteConfigSource(),
      compiledCloudModel: kHybridCloudModel,
    );
    return (services, HybridRuntime.create(remote: remote));
  }

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<(AppServices, HybridRuntime?)>(
        future: _services,
        builder: (context, snapshot) {
          if (snapshot.hasData) {
            final (services, hybrid) = snapshot.data!;
            return CookingApp(
              services: services,
              hybrid: hybrid,
              isDemo: kFakeBackend,
              pantryFirst: true,
              initialRecipeId: deepLinkRecipeId(),
            );
          }
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: cookingTheme,
            home: Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.soup_kitchen_outlined, size: 56),
                      const SizedBox(height: 20),
                      Text(
                        snapshot.hasError
                            ? 'Could not connect to your kitchen'
                            : 'Opening your kitchen…',
                        style: const TextStyle(fontSize: 24),
                      ),
                      const SizedBox(height: 20),
                      if (snapshot.hasError)
                        FilledButton(
                          onPressed: () => setState(() => _services = _load()),
                          child: const Text('Try again'),
                        )
                      else
                        const CircularProgressIndicator(),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
}
