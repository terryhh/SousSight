import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/core/models.dart';
import 'package:soussight/nearby/geolocation.dart';
import 'package:soussight/nearby/nearby_client.dart';
import 'package:soussight/nearby/nearby_sheet.dart';
import 'package:soussight/pantry/pantry_client.dart';
import 'package:soussight/pantry/pantry_screen.dart';
import 'package:soussight/pantry/recipe_catalog.dart';

class _RecordingNearby implements NearbyClient {
  final queries = <NearbyQuery>[];
  @override
  Future<NearbyResult> find(NearbyQuery query) {
    queries.add(query);
    return const FakeNearbyClient(delay: Duration.zero).find(query);
  }
}

void main() {
  late List<Recipe> recipes;

  Future<void> setUp360(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 780);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    recipes = (await tester.runAsync(loadRecipeCatalog))!;
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Widget screen({
    required NearbyClient nearby,
    required NearbyLocator locate,
    required List<Uri> opened,
  }) => MaterialApp(
    home: PantryScreen(
      recipes: recipes,
      client: const FakePantryClient(delay: Duration.zero),
      isDemo: true,
      nearbyClient: nearby,
      locate: locate,
      openLink: (uri) async => opened.add(uri),
      onChooseRecipe: (_, _) {},
    ),
  );

  testWidgets('food help sheet shows simulated places with Maps attribution', (
    tester,
  ) async {
    await setUp360(tester);
    final nearby = _RecordingNearby();
    final opened = <Uri>[];
    await tester.pumpWidget(
      screen(
        nearby: nearby,
        locate: () async => NearbyCoordinates(28.54, -81.38),
        opened: opened,
      ),
    );
    await tapVisible(tester, find.byKey(const ValueKey('nearby-food-help')));
    expect(find.text(nearbyLocationNotice), findsOneWidget);
    await tapVisible(tester, find.byKey(const ValueKey('nearby-use-location')));

    expect(nearby.queries.single.kind, NearbyKind.foodHelp);
    expect(nearby.queries.single.coordinates, isNotNull);
    expect(find.text('REHEARSAL · SIMULATED PLACES'), findsOneWidget);
    expect(find.text('Google Maps'), findsOneWidget);
    expect(find.text('Sources: '), findsOneWidget);
    expect(find.text(nearbyDisclaimer), findsOneWidget);
    final place = find.text('Sample Community Pantry (simulated)');
    expect(place, findsOneWidget);
    await tapVisible(tester, place);
    expect(opened.single.host, 'www.google.com');
    expect(opened.single.path, startsWith('/maps/'));
  });

  testWidgets('denied location falls back to a typed city or ZIP', (
    tester,
  ) async {
    await setUp360(tester);
    final nearby = _RecordingNearby();
    await tester.pumpWidget(
      screen(
        nearby: nearby,
        locate: () => Future.error(const LocationUnavailable()),
        opened: [],
      ),
    );
    await tapVisible(tester, find.byKey(const ValueKey('nearby-food-help')));
    await tapVisible(tester, find.byKey(const ValueKey('nearby-use-location')));
    expect(find.textContaining('Location is off or blocked'), findsOneWidget);
    expect(nearby.queries, isEmpty);

    await tester.enterText(find.byKey(const ValueKey('nearby-area')), '32801');
    await tapVisible(tester, find.byKey(const ValueKey('nearby-search-area')));
    expect(nearby.queries.single.area, '32801');
    expect(nearby.queries.single.coordinates, isNull);
    expect(find.text('Sample Community Pantry (simulated)'), findsOneWidget);
  });

  testWidgets('empty typed area uses the Orlando hint', (tester) async {
    await setUp360(tester);
    final nearby = _RecordingNearby();
    await tester.pumpWidget(
      screen(
        nearby: nearby,
        locate: () => Future.error(const LocationUnavailable()),
        opened: [],
      ),
    );
    await tapVisible(tester, find.byKey(const ValueKey('nearby-food-help')));
    await tapVisible(tester, find.byKey(const ValueKey('nearby-search-area')));
    expect(nearby.queries.single.area, kNearbyAreaHint);
  });

  testWidgets('meal with missing items searches for where to buy them', (
    tester,
  ) async {
    await setUp360(tester);
    final nearby = _RecordingNearby();
    await tester.pumpWidget(
      screen(
        nearby: nearby,
        locate: () async => NearbyCoordinates(28.54, -81.38),
        opened: [],
      ),
    );
    await tapVisible(tester, find.byKey(const ValueKey('find-meal')));
    // The peanut butter sandwich has nothing missing, so no action is offered.
    expect(
      find.byKey(const ValueKey('nearby-missing-peanut_butter_sandwich_v1')),
      findsNothing,
    );
    await tapVisible(
      tester,
      find.byKey(const ValueKey('nearby-missing-black_bean_corn_salsa_v1')),
    );
    expect(find.text('Where to get the missing items'), findsWidgets);
    await tapVisible(tester, find.byKey(const ValueKey('nearby-use-location')));
    final query = nearby.queries.single;
    expect(query.kind, NearbyKind.groceries);
    expect(query.missingItems, ['tortilla chips or tortillas']);
    expect(find.text('Sample Budget Grocery (simulated)'), findsOneWidget);
    expect(find.text('Google Maps'), findsOneWidget);
  });

  testWidgets('no grounded results shows an explicit message', (tester) async {
    await setUp360(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NearbyPanel(
            client: _NoResults(),
            kind: NearbyKind.foodHelp,
            locate: () async => NearbyCoordinates(1, 1),
            openLink: (_) async {},
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('nearby-search-area')));
    await tester.pumpAndSettle();
    expect(find.textContaining('could not find places'), findsOneWidget);
    expect(find.text('Google Maps'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _NoResults implements NearbyClient {
  @override
  Future<NearbyResult> find(NearbyQuery query) => Future.error(
    const NearbyException(
      NearbyFailure.noResults,
      'I could not find places on Google Maps for that area.',
    ),
  );
}
