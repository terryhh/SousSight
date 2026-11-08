import 'package:flutter/material.dart';

import 'app/services_scope.dart';
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
  late Future<AppServices> _services = _load();
  Future<AppServices> _load() => kFakeBackend
      ? fakeServices()
      : firebaseServices();

  @override
  Widget build(BuildContext context) => FutureBuilder<AppServices>(
    future: _services,
    builder: (context, snapshot) {
      if (snapshot.hasData) {
        return CookingApp(
          services: snapshot.data!,
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
