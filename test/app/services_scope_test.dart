import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/app/services_scope.dart';
import 'package:soussight/core/analytics.dart';
import 'package:soussight/core/fakes.dart';
import 'package:soussight/core/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Asset loads happen here, outside testWidgets' fake-async zone.
  late Recipe recipe;
  setUpAll(() async => recipe = await loadBundledRecipe());

  AppServices servicesFor(Recipe recipe) => AppServices(
    auth: FakeAuthService(),
    recipes: FakeRecipeRepository(recipe),
    sessions: FakeSessionRepository(),
    bundledRecipe: recipe,
  );

  test('fake services run the bundled recipe with no backend', () async {
    final services = await fakeServices();
    expect(services.bundledRecipe.id, kRecipeId);
    expect(services.auth, isA<FakeAuthService>());
    expect(services.sessions, isA<FakeSessionRepository>());
    expect(services.analytics, isA<NoopAnalytics>());
    final watched = await services.recipes.watch(kRecipeId).first;
    expect(watched.id, kRecipeId);
    expect(services.clock().isAfter(DateTime(2026)), isTrue);
  });

  testWidgets('descendants read the services and rebuild only on a change', (
    tester,
  ) async {
    final first = servicesFor(recipe);
    final second = servicesFor(recipe);
    final seen = <AppServices>[];
    final probe = Builder(
      builder: (context) {
        seen.add(ServicesScope.of(context));
        return const SizedBox();
      },
    );

    await tester.pumpWidget(ServicesScope(services: first, child: probe));
    await tester.pumpWidget(ServicesScope(services: first, child: probe));
    expect(seen, [same(first)], reason: 'same services: no rebuild');

    await tester.pumpWidget(ServicesScope(services: second, child: probe));
    expect(seen, [same(first), same(second)]);
  });
}
